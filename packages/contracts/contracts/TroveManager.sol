// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/ITroveManager.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/ILUSDToken.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Interfaces/ILQTYStaking.sol";
import "./Dependencies/LiquityBase.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";

contract TroveManager is LiquityBase, Ownable, CheckContract, ITroveManager {

    // --- Connected contract declarations ---

    address public borrowerOperationsAddress;

    IStabilityPool public stabilityPool;

    address gasPoolAddress;

    ICollSurplusPool collSurplusPool;

    ILUSDToken public lusdToken;

    ILQTYStaking public lqtyStaking;

    // A doubly linked list of Troves, sorted by their sorted by their collateral ratios
    ISortedTroves public sortedTroves;

    // --- Data structures ---

    uint constant public SECONDS_IN_ONE_MINUTE = 60;
    uint constant public MINUTE_DECAY_FACTOR = 999832508430720967;  // 18 digit decimal. Corresponds to an hourly decay factor of 0.99

    /*
    * BETA: 18 digit decimal. Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
    * Corresponds to (1 / ALPHA) in the white paper.
    */
    uint constant public BETA = 2;

    uint public baseRate;

    // The timestamp of the latest fee operation (redemption or new LUSD issuance)
    uint public lastFeeOperationTime;

    enum Status { nonExistent, active, closed }

    // Store the necessary data for a trove
    struct Trove {
        uint debt;
        uint coll;
        uint stake;
        Status status;
        uint128 arrayIndex;
    }

    mapping (address => Trove) public Troves;

    uint public totalStakes;

    // Snapshot of the value of totalStakes, taken immediately after the latest liquidation
    uint public totalStakesSnapshot;

    // Snapshot of the total collateral across the ActivePool and DefaultPool, immediately after the latest liquidation.
    uint public totalCollateralSnapshot;

    /*
    * L_ETH and L_LUSDDebt track the sums of accumulated liquidation rewards per unit staked. During its lifetime, each stake earns:
    *
    * An ETH gain of ( stake * [L_ETH - L_ETH(0)] )
    * A LUSDDebt increase  of ( stake * [L_LUSDDebt - L_LUSDDebt(0)] )
    *
    * Where L_ETH(0) and L_LUSDDebt(0) are snapshots of L_ETH and L_LUSDDebt for the active Trove taken at the instant the stake was made
    */
    uint public L_ETH;
    uint public L_LUSDDebt;

    // Map addresses with active troves to their RewardSnapshot
    mapping (address => RewardSnapshot) public rewardSnapshots;

    // Object containing the ETH and LUSD snapshots for a given active trove
    struct RewardSnapshot { uint ETH; uint LUSDDebt;}

    // Array of all active trove addresses - used to to compute an approximate hint off-chain, for the sorted list insertion
    address[] public TroveOwners;

    // Error trackers for the trove redistribution calculation
    uint public lastETHError_Redistribution;
    uint public lastLUSDDebtError_Redistribution;

    /*
    * --- Variable container structs for liquidations ---
    *
    * These structs are used to hold, return and assign variables inside the liquidation functions,
    * in order to avoid the error: "CompilerError: Stack too deep".
    **/

    struct LocalVariables_OuterLiquidationFunction {
        uint price;
        uint LUSDInStabPool;
        bool recoveryModeAtStart;
        uint liquidatedDebt;
        uint liquidatedColl;
    }

    struct LocalVariables_InnerSingleLiquidateFunction {
        uint collToLiquidate;
        uint pendingDebtReward;
        uint pendingCollReward;
    }

    struct LocalVariables_LiquidationSequence {
        uint remainingLUSDInStabPool;
        uint i;
        uint ICR;
        address user;
        bool backToNormalMode;
        uint entireSystemDebt;
        uint entireSystemColl;
    }

    struct LiquidationValues {
        uint entireTroveDebt;
        uint entireTroveColl;
        uint collGasCompensation;
        uint LUSDGasCompensation;
        uint debtToOffset;
        uint collToSendToSP;
        uint debtToRedistribute;
        uint collToRedistribute;
        uint collSurplus;
    }

    struct LiquidationTotals {
        uint totalCollInSequence;
        uint totalDebtInSequence;
        uint totalCollGasCompensation;
        uint totalLUSDGasCompensation;
        uint totalDebtToOffset;
        uint totalCollToSendToSP;
        uint totalDebtToRedistribute;
        uint totalCollToRedistribute;
        uint totalCollSurplus;
    }

    // --- Variable container structs for redemptions ---

    struct RedemptionTotals {
        uint remainingLUSD;
        uint totalLUSDToRedeem;
        uint totalETHDrawn;
        uint ETHFee;
        uint ETHToSendToRedeemer;
        uint decayedBaseRate;
    }

    struct SingleRedemptionValues {
        uint LUSDLot;
        uint ETHLot;
    }

    // --- Events ---

    event Liquidation(uint _liquidatedDebt, uint _liquidatedColl, uint _collGasCompensation, uint _LUSDGasCompensation);
    event Redemption(uint _attemptedLUSDAmount, uint _actualLUSDAmount, uint _ETHSent, uint _ETHFee);

    enum TroveManagerOperation {
        applyPendingRewards,
        liquidateInNormalMode,
        liquidateInRecoveryMode,
        redeemCollateral
    }

    event TroveCreated(address indexed _borrower, uint _arrayIndex);
    event TroveUpdated(address indexed _borrower, uint _debt, uint _coll, uint _stake, TroveManagerOperation _operation);
    event TroveLiquidated(address indexed _borrower, uint _debt, uint _coll, TroveManagerOperation _operation);

    // --- Dependency setter ---

    function setAddresses(
        address _borrowerOperationsAddress,
        address _activePoolAddress,
        address _defaultPoolAddress,
        address _stabilityPoolAddress,
        address _gasPoolAddress,
        address _collSurplusPoolAddress,
        address _priceFeedAddress,
        address _lusdTokenAddress,
        address _sortedTrovesAddress,
        address _lqtyStakingAddress
    )
        external
        override
        onlyOwner
    {
        checkContract(_borrowerOperationsAddress);
        checkContract(_activePoolAddress);
        checkContract(_defaultPoolAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_gasPoolAddress);
        checkContract(_collSurplusPoolAddress);
        checkContract(_priceFeedAddress);
        checkContract(_lusdTokenAddress);
        checkContract(_sortedTrovesAddress);
        checkContract(_lqtyStakingAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        activePool = IActivePool(_activePoolAddress);
        defaultPool = IDefaultPool(_defaultPoolAddress);
        stabilityPool = IStabilityPool(_stabilityPoolAddress);
        gasPoolAddress = _gasPoolAddress;
        collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
        priceFeed = IPriceFeed(_priceFeedAddress);
        lusdToken = ILUSDToken(_lusdTokenAddress);
        sortedTroves = ISortedTroves(_sortedTrovesAddress);
        lqtyStaking = ILQTYStaking(_lqtyStakingAddress);

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);
        emit DefaultPoolAddressChanged(_defaultPoolAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
        emit GasPoolAddressChanged(_gasPoolAddress);
        emit CollSurplusPoolAddressChanged(_collSurplusPoolAddress);
        emit PriceFeedAddressChanged(_priceFeedAddress);
        emit LUSDTokenAddressChanged(_lusdTokenAddress);
        emit SortedTrovesAddressChanged(_sortedTrovesAddress);
        emit LQTYStakingAddressChanged(_lqtyStakingAddress);

        _renounceOwnership();
    }

    // --- Getters ---

    function getTroveOwnersCount() external view override returns (uint) {
        return TroveOwners.length;
    }

    function getTroveFromTroveOwnersArray(uint _index) external view override returns (address) {
        return TroveOwners[_index];
    }

    // --- Trove Liquidation functions ---

    // Single liquidation function. Closes the trove if its ICR is lower than the minimum collateral ratio.
    function liquidate(address _borrower) external override {
        _requireTroveisActive(_borrower);

        address[] memory borrowers = new address[](1);
        borrowers[0] = _borrower;
        batchLiquidateTroves(borrowers);
    }

    // --- Inner single liquidation functions ---

    // Liquidate one trove, in Normal Mode.
    function _liquidateNormalMode(address _borrower, uint _LUSDInStabPool) internal returns (LiquidationValues memory singleLiquidation) {
        LocalVariables_InnerSingleLiquidateFunction memory vars;

        (singleLiquidation.entireTroveDebt,
        singleLiquidation.entireTroveColl,
        vars.pendingDebtReward,
        vars.pendingCollReward) = getEntireDebtAndColl(_borrower);

        _movePendingTroveRewardsToActivePool(vars.pendingDebtReward, vars.pendingCollReward);
        _removeStake(_borrower);

        singleLiquidation.collGasCompensation = _getCollGasCompensation(singleLiquidation.entireTroveColl);
        singleLiquidation.LUSDGasCompensation = LUSD_GAS_COMPENSATION;
        uint collToLiquidate = singleLiquidation.entireTroveColl.sub(singleLiquidation.collGasCompensation);

        (singleLiquidation.debtToOffset,
        singleLiquidation.collToSendToSP,
        singleLiquidation.debtToRedistribute,
        singleLiquidation.collToRedistribute) = _getOffsetAndRedistributionVals(singleLiquidation.entireTroveDebt, collToLiquidate, _LUSDInStabPool);

        _closeTrove(_borrower);
        emit TroveLiquidated(_borrower, singleLiquidation.entireTroveDebt, singleLiquidation.entireTroveColl, TroveManagerOperation.liquidateInNormalMode);

        return singleLiquidation;
    }

    // Liquidate one trove, in Recovery Mode.
    function _liquidateRecoveryMode(
        address _borrower,
        uint _ICR,
        uint _LUSDInStabPool,
        uint _TCR,
        uint _price
    )
        internal
        returns (LiquidationValues memory singleLiquidation)
    {
        LocalVariables_InnerSingleLiquidateFunction memory vars;

        if (TroveOwners.length <= 1) {return singleLiquidation;} // don't liquidate if last trove

        (singleLiquidation.entireTroveDebt,
        singleLiquidation.entireTroveColl,
        vars.pendingDebtReward,
        vars.pendingCollReward) = getEntireDebtAndColl(_borrower);

        _movePendingTroveRewardsToActivePool(vars.pendingDebtReward, vars.pendingCollReward);

        singleLiquidation.collGasCompensation = _getCollGasCompensation(singleLiquidation.entireTroveColl);
        singleLiquidation.LUSDGasCompensation = LUSD_GAS_COMPENSATION;
        vars.collToLiquidate = singleLiquidation.entireTroveColl.sub(singleLiquidation.collGasCompensation);

        // If ICR <= 100%, purely redistribute the Trove across all active Troves
        if (_ICR <= _100pct) {
            _removeStake(_borrower);

            singleLiquidation.debtToOffset = 0;
            singleLiquidation.collToSendToSP = 0;
            singleLiquidation.debtToRedistribute = singleLiquidation.entireTroveDebt;
            singleLiquidation.collToRedistribute = vars.collToLiquidate;

            _closeTrove(_borrower);
            emit TroveLiquidated(_borrower, singleLiquidation.entireTroveDebt, singleLiquidation.entireTroveColl, TroveManagerOperation.liquidateInRecoveryMode);

        // If 100% < ICR < MCR, offset as much as possible, and redistribute the remainder
        } else if ((_ICR > _100pct) && (_ICR < MCR)) {
            _removeStake(_borrower);

            (singleLiquidation.debtToOffset,
            singleLiquidation.collToSendToSP,
            singleLiquidation.debtToRedistribute,
            singleLiquidation.collToRedistribute) = _getOffsetAndRedistributionVals(singleLiquidation.entireTroveDebt, vars.collToLiquidate, _LUSDInStabPool);

            _closeTrove(_borrower);
            emit TroveLiquidated(_borrower, singleLiquidation.entireTroveDebt, singleLiquidation.entireTroveColl, TroveManagerOperation.liquidateInRecoveryMode);

        /*
        * If 110% <= ICR < current TCR (accounting for the preceding liquidations in the current sequence)
        * and there is LUSD in the Stability Pool, only offset, with no redistribution,
        * but at a capped rate of 1.1 and only if the whole debt can be liquidated.
        * The remainder due to the capped rate will be claimable as collateral surplus.
        */
        } else if ((_ICR >= MCR) && (_ICR < _TCR) && (singleLiquidation.entireTroveDebt <= _LUSDInStabPool)) {
            assert(_LUSDInStabPool != 0);

            _removeStake(_borrower);

            singleLiquidation = _getCappedOffsetVals(singleLiquidation.entireTroveDebt, singleLiquidation.entireTroveColl, _price);

            _closeTrove(_borrower);
            if (singleLiquidation.collSurplus > 0) {
                collSurplusPool.accountSurplus(_borrower, singleLiquidation.collSurplus);
            }

            emit TroveLiquidated(_borrower, singleLiquidation.entireTroveDebt, singleLiquidation.collToSendToSP, TroveManagerOperation.liquidateInRecoveryMode);

        } else { // if (_ICR >= _TCR || (MCR <= _ICR < _TCR && singleLiquidation.entireTroveDebt > _LUSDInStabPool))
            LiquidationValues memory zeroVals;
            return zeroVals;
        }

        return singleLiquidation;
    }

    /* In a full liquidation, returns the values for a trove's coll and debt to be offset, and coll and debt to be
    * redistributed to active troves.
    */
    function _getOffsetAndRedistributionVals
    (
        uint _debt,
        uint _coll,
        uint _LUSDInStabPool
    )
        internal
        pure
        returns (uint debtToOffset, uint collToSendToSP, uint debtToRedistribute, uint collToRedistribute)
    {
        if (_LUSDInStabPool > 0) {
        /*
        * Offset as much debt & collateral as possible against the Stability Pool, and redistribute the remainder
        * between all active troves.
        *
        *  If the trove's debt is larger than the deposited LUSD in the Stability Pool:
        *
        *  - Offset an amount of the trove's debt equal to the LUSD in the Stability Pool
        *  - Send a fraction of the trove's collateral to the Stability Pool, equal to the fraction of its offset debt
        *
        */
            debtToOffset = LiquityMath._min(_debt, _LUSDInStabPool);
            collToSendToSP = _coll.mul(debtToOffset).div(_debt);
            debtToRedistribute = _debt.sub(debtToOffset);
            collToRedistribute = _coll.sub(collToSendToSP);
        } else {
            debtToOffset = 0;
            collToSendToSP = 0;
            debtToRedistribute = _debt;
            collToRedistribute = _coll;
        }
    }

    /*
    *  Get its offset coll/debt and ETH gas comp, and close the trove.
    */
    function _getCappedOffsetVals
    (
        uint _entireTroveDebt,
        uint _entireTroveColl,
        uint _price
    )
        internal
        pure
        returns (LiquidationValues memory singleLiquidation)
    {
        singleLiquidation.entireTroveDebt = _entireTroveDebt;
        singleLiquidation.entireTroveColl = _entireTroveColl;
        uint collToOffset = _entireTroveDebt.mul(MCR).div(_price);

        singleLiquidation.collGasCompensation = _getCollGasCompensation(collToOffset);
        singleLiquidation.LUSDGasCompensation = LUSD_GAS_COMPENSATION;

        singleLiquidation.debtToOffset = _entireTroveDebt;
        singleLiquidation.collToSendToSP = collToOffset.sub(singleLiquidation.collGasCompensation);
        singleLiquidation.collSurplus = _entireTroveColl.sub(collToOffset);
        singleLiquidation.debtToRedistribute = 0;
        singleLiquidation.collToRedistribute = 0;
    }

    /*
    * Liquidate a sequence of troves. Closes a maximum number of n under-collateralized Troves,
    * starting from the one with the lowest collateral ratio in the system, and moving upwards
    */
    function liquidateTroves(uint _n) external override {
        LocalVariables_OuterLiquidationFunction memory vars;

        LiquidationTotals memory totals;

        vars.price = priceFeed.getPrice();
        vars.LUSDInStabPool = stabilityPool.getTotalLUSDDeposits();
        vars.recoveryModeAtStart = _checkRecoveryMode();

        // Perform the appropriate liquidation sequence - tally the values, and obtain their totals
        if (vars.recoveryModeAtStart) {
            totals = _getTotalsFromLiquidateTrovesSequence_RecoveryMode(vars.price, vars.LUSDInStabPool, _n);
        } else { // if !vars.recoveryModeAtStart
            totals = _getTotalsFromLiquidateTrovesSequence_NormalMode(vars.price, vars.LUSDInStabPool, _n);
        }

        require(totals.totalDebtInSequence > 0, "TroveManager: nothing to liquidate");

        // Move liquidated ETH and LUSD to the appropriate pools
        stabilityPool.offset(totals.totalDebtToOffset, totals.totalCollToSendToSP);
        _redistributeDebtAndColl(totals.totalDebtToRedistribute, totals.totalCollToRedistribute);
        if (totals.totalCollSurplus > 0) {
            activePool.sendETH(address(collSurplusPool), totals.totalCollSurplus);
        }

        // Update system snapshots
        _updateSystemSnapshots_excludeCollRemainder(totals.totalCollGasCompensation);

        vars.liquidatedDebt = totals.totalDebtInSequence;
        vars.liquidatedColl = totals.totalCollInSequence.sub(totals.totalCollGasCompensation).sub(totals.totalCollSurplus);
        emit Liquidation(vars.liquidatedDebt, vars.liquidatedColl, totals.totalCollGasCompensation, totals.totalLUSDGasCompensation);

        // Send gas compensation to caller
        _sendGasCompensation(msg.sender, totals.totalLUSDGasCompensation, totals.totalCollGasCompensation);
    }

    /*
    * This function is used when the liquidateTroves sequence starts during Recovery Mode. However, it
    * handle the case where the system *leaves* Recovery Mode, part way through the liquidation sequence
    */
    function _getTotalsFromLiquidateTrovesSequence_RecoveryMode
    (
        uint _price,
        uint _LUSDInStabPool,
        uint _n
    )
        internal
        returns(LiquidationTotals memory totals)
    {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;

        vars.remainingLUSDInStabPool = _LUSDInStabPool;
        vars.backToNormalMode = false;
        vars.entireSystemDebt = getEntireSystemDebt();
        vars.entireSystemColl = getEntireSystemColl();

        vars.user = sortedTroves.getLast();
        address firstUser = sortedTroves.getFirst();
        for (vars.i = 0; vars.i < _n && vars.user != firstUser; vars.i++) {
            // we need to cache it, because current user is likely going to be deleted
            address nextUser = sortedTroves.getPrev(vars.user);

            vars.ICR = getCurrentICR(vars.user, _price);

            if (!vars.backToNormalMode) {
                // Break the loop if ICR is greater than MCR and Stability Pool is empty
                if (vars.ICR >= MCR && vars.remainingLUSDInStabPool == 0) { break; }

                uint TCR = LiquityMath._computeCR(vars.entireSystemColl, vars.entireSystemDebt, _price);

                singleLiquidation = _liquidateRecoveryMode(vars.user, vars.ICR, vars.remainingLUSDInStabPool, TCR, _price);

                // Update aggregate trackers
                vars.remainingLUSDInStabPool = vars.remainingLUSDInStabPool.sub(singleLiquidation.debtToOffset);
                vars.entireSystemDebt = vars.entireSystemDebt.sub(singleLiquidation.debtToOffset);
                vars.entireSystemColl = vars.entireSystemColl.sub(singleLiquidation.collToSendToSP).sub(singleLiquidation.collSurplus);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

                vars.backToNormalMode = !_checkPotentialRecoveryMode(vars.entireSystemColl, vars.entireSystemDebt, _price);
            }
            else if (vars.backToNormalMode && vars.ICR < MCR) {
                singleLiquidation = _liquidateNormalMode(vars.user, vars.remainingLUSDInStabPool);

                vars.remainingLUSDInStabPool = vars.remainingLUSDInStabPool.sub(singleLiquidation.debtToOffset);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

            }  else break;  // break if the loop reaches a Trove with ICR >= MCR

            vars.user = nextUser;
        }
    }

    function _getTotalsFromLiquidateTrovesSequence_NormalMode
    (
        uint _price,
        uint _LUSDInStabPool,
        uint _n
    )
        internal
        returns(LiquidationTotals memory totals)
    {
        LocalVariables_LiquidationSequence memory vars;  
        LiquidationValues memory singleLiquidation;

        vars.remainingLUSDInStabPool = _LUSDInStabPool;

        for (vars.i = 0; vars.i < _n; vars.i++) {
            vars.user = sortedTroves.getLast();
            vars.ICR = getCurrentICR(vars.user, _price);

            if (vars.ICR < MCR) {
                singleLiquidation = _liquidateNormalMode(vars.user, vars.remainingLUSDInStabPool);

                vars.remainingLUSDInStabPool = vars.remainingLUSDInStabPool.sub(singleLiquidation.debtToOffset);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

            } else break;  // break if the loop reaches a Trove with ICR >= MCR
        }
    }

    /*
    * Attempt to liquidate a custom list of troves provided by the caller.
    */
    function batchLiquidateTroves(address[] memory _troveArray) public override {
        require(_troveArray.length != 0, "TroveManager: Calldata address array must not be empty");

        LocalVariables_OuterLiquidationFunction memory vars;
        LiquidationTotals memory totals;

        vars.price = priceFeed.getPrice();
        vars.LUSDInStabPool = stabilityPool.getTotalLUSDDeposits();
        vars.recoveryModeAtStart = _checkRecoveryMode();

        // Perform the appropriate liquidation sequence - tally values and obtain their totals.
        if (vars.recoveryModeAtStart) {
           totals = _getTotalFromBatchLiquidate_RecoveryMode(vars.price, vars.LUSDInStabPool, _troveArray);
        } else {  //  if !vars.recoveryModeAtStart
            totals = _getTotalsFromBatchLiquidate_NormalMode(vars.price, vars.LUSDInStabPool, _troveArray);
        }

        require(totals.totalDebtInSequence > 0, "TroveManager: nothing to liquidate");

        // Move liquidated ETH and LUSD to the appropriate pools
        stabilityPool.offset(totals.totalDebtToOffset, totals.totalCollToSendToSP);
        _redistributeDebtAndColl(totals.totalDebtToRedistribute, totals.totalCollToRedistribute);
        if (totals.totalCollSurplus > 0) {
            activePool.sendETH(address(collSurplusPool), totals.totalCollSurplus);
        }

        // Update system snapshots
        _updateSystemSnapshots_excludeCollRemainder(totals.totalCollGasCompensation);

        vars.liquidatedDebt = totals.totalDebtInSequence;
        vars.liquidatedColl = totals.totalCollInSequence.sub(totals.totalCollGasCompensation).sub(totals.totalCollSurplus);
        emit Liquidation(vars.liquidatedDebt, vars.liquidatedColl, totals.totalCollGasCompensation, totals.totalLUSDGasCompensation);

        // Send gas compensation to caller
        _sendGasCompensation(msg.sender, totals.totalLUSDGasCompensation, totals.totalCollGasCompensation);
    }

    /*
    * This function is used when the batch liquidation sequence starts during Recovery Mode. However, it
    * handle the case where the system *leaves* Recovery Mode, part way through the liquidation sequence
    */
    function _getTotalFromBatchLiquidate_RecoveryMode
    (
        uint _price,
        uint _LUSDInStabPool,
        address[] memory _troveArray)
        internal
        returns(LiquidationTotals memory totals)
    {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;

        vars.remainingLUSDInStabPool = _LUSDInStabPool;
        vars.backToNormalMode = false;
        vars.entireSystemDebt = getEntireSystemDebt();
        vars.entireSystemColl = getEntireSystemColl();

        for (vars.i = 0; vars.i < _troveArray.length; vars.i++) {
            vars.user = _troveArray[vars.i];
            vars.ICR = getCurrentICR(vars.user, _price);

            if (!vars.backToNormalMode) {

                // Skip this trove if ICR is greater than MCR and Stability Pool is empty
                if (vars.ICR >= MCR && vars.remainingLUSDInStabPool == 0) { continue; }

                uint TCR = LiquityMath._computeCR(vars.entireSystemColl, vars.entireSystemDebt, _price);

                singleLiquidation = _liquidateRecoveryMode(vars.user, vars.ICR, vars.remainingLUSDInStabPool, TCR, _price);

                // Update aggregate trackers
                vars.remainingLUSDInStabPool = vars.remainingLUSDInStabPool.sub(singleLiquidation.debtToOffset);
                vars.entireSystemDebt = vars.entireSystemDebt.sub(singleLiquidation.debtToOffset);
                vars.entireSystemColl = vars.entireSystemColl.sub(singleLiquidation.collToSendToSP);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

                vars.backToNormalMode = !_checkPotentialRecoveryMode(vars.entireSystemColl, vars.entireSystemDebt, _price);
            }

            else if (vars.backToNormalMode && vars.ICR < MCR) {
                singleLiquidation = _liquidateNormalMode(vars.user, vars.remainingLUSDInStabPool);
                vars.remainingLUSDInStabPool = vars.remainingLUSDInStabPool.sub(singleLiquidation.debtToOffset);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

            } else continue; // In Normal Mode skip troves with ICR >= MCR
        }
    }

    function _getTotalsFromBatchLiquidate_NormalMode
    (
        uint _price,
        uint _LUSDInStabPool,
        address[] memory _troveArray
    )
        internal
        returns(LiquidationTotals memory totals)
    {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;

        vars.remainingLUSDInStabPool = _LUSDInStabPool;

        for (vars.i = 0; vars.i < _troveArray.length; vars.i++) {
            vars.user = _troveArray[vars.i];
            vars.ICR = getCurrentICR(vars.user, _price);

            if (vars.ICR < MCR) {
                singleLiquidation = _liquidateNormalMode(vars.user, vars.remainingLUSDInStabPool);
                vars.remainingLUSDInStabPool = vars.remainingLUSDInStabPool.sub(singleLiquidation.debtToOffset);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
            }
        }
    }

    // --- Liquidation helper functions ---

    function _addLiquidationValuesToTotals(LiquidationTotals memory oldTotals, LiquidationValues memory singleLiquidation)
    internal pure returns(LiquidationTotals memory newTotals) {

        // Tally all the values with their respective running totals
        newTotals.totalCollGasCompensation = oldTotals.totalCollGasCompensation.add(singleLiquidation.collGasCompensation);
        newTotals.totalLUSDGasCompensation = oldTotals.totalLUSDGasCompensation.add(singleLiquidation.LUSDGasCompensation);
        newTotals.totalDebtInSequence = oldTotals.totalDebtInSequence.add(singleLiquidation.entireTroveDebt);
        newTotals.totalCollInSequence = oldTotals.totalCollInSequence.add(singleLiquidation.entireTroveColl);
        newTotals.totalDebtToOffset = oldTotals.totalDebtToOffset.add(singleLiquidation.debtToOffset);
        newTotals.totalCollToSendToSP = oldTotals.totalCollToSendToSP.add(singleLiquidation.collToSendToSP);
        newTotals.totalDebtToRedistribute = oldTotals.totalDebtToRedistribute.add(singleLiquidation.debtToRedistribute);
        newTotals.totalCollToRedistribute = oldTotals.totalCollToRedistribute.add(singleLiquidation.collToRedistribute);
        newTotals.totalCollSurplus = oldTotals.totalCollSurplus.add(singleLiquidation.collSurplus);

        return newTotals;
    }

    function _sendGasCompensation(address _liquidator, uint _LUSD, uint _ETH) internal {
        if (_LUSD > 0) {
            lusdToken.returnFromPool(gasPoolAddress, _liquidator, _LUSD);
        }

        if (_ETH > 0) {
            activePool.sendETH(_liquidator, _ETH);
        }
    }

    // Move a Trove's pending debt and collateral rewards from distributions, from the Default Pool to the Active Pool
    function _movePendingTroveRewardsToActivePool(uint _LUSD, uint _ETH) internal {
        defaultPool.decreaseLUSDDebt(_LUSD);
        activePool.increaseLUSDDebt(_LUSD);
        defaultPool.sendETHToActivePool(_ETH);
    }

    // --- Redemption functions ---

    // Redeem as much collateral as possible from _borrower's Trove in exchange for LUSD up to _maxLUSDamount
    function _redeemCollateralFromTrove(
        address _borrower,
        uint _maxLUSDamount,
        uint _price,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint _partialRedemptionHintNICR
    )
        internal returns (SingleRedemptionValues memory singleRedemption)
    {
        // Determine the remaining amount (lot) to be redeemed, capped by the entire debt of the Trove minus the gas compensation
        singleRedemption.LUSDLot = LiquityMath._min(_maxLUSDamount, Troves[_borrower].debt.sub(LUSD_GAS_COMPENSATION));

        // Get the ETHLot of equivalent value in USD
        singleRedemption.ETHLot = singleRedemption.LUSDLot.mul(DECIMAL_PRECISION).div(_price);

        // Decrease the debt and collateral of the current Trove according to the LUSD lot and corresponding ETH to send
        uint newDebt = (Troves[_borrower].debt).sub(singleRedemption.LUSDLot);
        uint newColl = (Troves[_borrower].coll).sub(singleRedemption.ETHLot);

        if (newDebt == LUSD_GAS_COMPENSATION) {
            // No debt left in the Trove (except for the gas compensation), therefore the trove gets closed
            _removeStake(_borrower);
            _closeTrove(_borrower);
            _redeemCloseTrove(_borrower, LUSD_GAS_COMPENSATION, newColl);
            emit TroveUpdated(_borrower, 0, 0, 0, TroveManagerOperation.redeemCollateral);

        } else {
            uint newNICR = LiquityMath._computeNominalCR(newColl, newDebt);

            // Check if the provided hint is fresh. If not, we bail since trying to reinsert without a good hint will almost
            // certainly result in running out of gas.
            if (newNICR != _partialRedemptionHintNICR) {
                singleRedemption.LUSDLot = 0;
                singleRedemption.ETHLot = 0;
                return singleRedemption;
            }

            sortedTroves.reInsert(_borrower, newNICR, _upperPartialRedemptionHint, _lowerPartialRedemptionHint);

            Troves[_borrower].debt = newDebt;
            Troves[_borrower].coll = newColl;
            _updateStakeAndTotalStakes(_borrower);

            emit TroveUpdated(
                _borrower,
                newDebt, newColl,
                Troves[_borrower].stake,
                TroveManagerOperation.redeemCollateral
            );
        }

        return singleRedemption;
    }

    /*
    * Called when a full redemption occurs, and closes the trove.
    * The redeemer swaps (debt - 10) LUSD for (debt - 10) worth of ETH, so the 10 LUSD gas compensation left corresponds to the remaining debt.
    * In order to close the trove, the 10 LUSD gas compensation is burned, and 10 debt is removed from the active pool.
    * The debt recorded on the trove's struct is zero'd elswhere, in _closeTrove.
    * Any surplus ETH left in the trove, is sent to the Coll surplus pool, and can be later claimed by the borrower.
    */
    function _redeemCloseTrove(address _borrower, uint _LUSD, uint _ETH) internal {
        lusdToken.burn(gasPoolAddress, _LUSD);
        // Update Active Pool LUSD, and send ETH to account
        activePool.decreaseLUSDDebt(_LUSD);

        _sendCollSurplus(_borrower, _ETH);
    }

    function _sendCollSurplus(address _borrower, uint _ETH) internal {
        // send ETH from Active Pool to CollSurplus Pool
        collSurplusPool.accountSurplus(_borrower, _ETH);
        activePool.sendETH(address(collSurplusPool), _ETH);
    }

    function _isValidFirstRedemptionHint(address _firstRedemptionHint, uint _price) internal view returns (bool) {
        if (_firstRedemptionHint == address(0) ||
            !sortedTroves.contains(_firstRedemptionHint) ||
            getCurrentICR(_firstRedemptionHint, _price) < MCR
        ) {
            return false;
        }

        address nextTrove = sortedTroves.getNext(_firstRedemptionHint);
        return nextTrove == address(0) || getCurrentICR(nextTrove, _price) < MCR;
    }

    /* Send _LUSDamount LUSD to the system and redeem the corresponding amount of collateral from as many Troves as are needed to fill the redemption
    * request.  Applies pending rewards to a Trove before reducing its debt and coll.
    *
    * Note that if _amount is very large, this function can run out of gas, specially if traversed troves are small. This can be easily avoided by
    * splitting the total _amount in appropriate chunks and calling the function multiple times.
    *
    * Param `_maxIterations` can also be provided, so the loop through Troves is capped (if it’s zero, it will be ignored).This makes it easier to
    * avoid OOG for the frontend, as only knowing approximately the average cost of an iteration is enough, without needing to know the “topology”
    * of the trove list. It also avoids the need to set the cap in stone in the contract, nor doing gas calculations, as both gas price and opcode
    * costs can vary.
    *
    * All Troves that are redeemed from -- with the likely exception of the last one -- will end up with no debt left, therefore they will be closed.
    * If the last Trove does have some remaining debt, it has a finite ICR, and the reinsertion could be anywhere in the list, therefore it requires a hint.
    * A frontend should use getRedemptionHints() to calculate what the ICR of this Trove will be after redemption, and pass a hint for its position
    * in the sortedTroves list along with the ICR value that the hint was found for.
    *
    * If another transaction modifies the list between calling getRedemptionHints() and passing the hints to redeemCollateral(), it
    * is very likely that the last (partially) redeemed Trove would end up with a different ICR than what the hint is for. In this case the
    * redemption will stop after the last completely redeemed Trove and the sender will keep the remaining LUSD amount, which they can attempt
    * to redeem later.
    */
    function redeemCollateral(
        uint _LUSDamount,
        address _firstRedemptionHint,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint _partialRedemptionHintNICR,
        uint _maxIterations,
        uint _maxFee
    )
        external
        override
    {
        _requireTCRoverMCR();
        _requireAmountGreaterThanZero(_LUSDamount);
        _requireLUSDBalanceCoversRedemption(msg.sender, _LUSDamount);

        uint entireSystemDebt = getEntireSystemDebt();       
        // Confirm redeemer's balance is less than total systemic debt
        assert(lusdToken.balanceOf(msg.sender) <= entireSystemDebt);

        uint price = priceFeed.getPrice();
        
        RedemptionTotals memory totals;
        totals.remainingLUSD = _LUSDamount;
        address currentBorrower;

        if (_isValidFirstRedemptionHint(_firstRedemptionHint, price)) {
            currentBorrower = _firstRedemptionHint;
        } else {
            currentBorrower = sortedTroves.getLast();
            // Find the first trove with ICR >= MCR
            while (currentBorrower != address(0) && getCurrentICR(currentBorrower, price) < MCR) {
                currentBorrower = sortedTroves.getPrev(currentBorrower);
            }
        }

        // Loop through the Troves starting from the one with lowest collateral ratio until _amount of LUSD is exchanged for collateral
        if (_maxIterations == 0) { _maxIterations = uint(-1); }
        while (currentBorrower != address(0) && totals.remainingLUSD > 0 && _maxIterations > 0) {
            _maxIterations--;
            // Save the address of the Trove preceding the current one, before potentially modifying the list
            address nextUserToCheck = sortedTroves.getPrev(currentBorrower);

            _applyPendingRewards(currentBorrower);

            SingleRedemptionValues memory singleRedemption = _redeemCollateralFromTrove(
                currentBorrower,
                totals.remainingLUSD,
                price,
                _upperPartialRedemptionHint,
                _lowerPartialRedemptionHint,
                _partialRedemptionHintNICR
            );

            if (singleRedemption.LUSDLot == 0) break; // Partial redemption hint got out-of-date, therefore we could not redeem from the last Trove

            totals.totalLUSDToRedeem  = totals.totalLUSDToRedeem.add(singleRedemption.LUSDLot);
            totals.totalETHDrawn = totals.totalETHDrawn.add(singleRedemption.ETHLot);

            totals.remainingLUSD = totals.remainingLUSD.sub(singleRedemption.LUSDLot);
            currentBorrower = nextUserToCheck;
        }

        // Decay the baseRate due to time passed, and then increase it according to the size of this redemption
        _updateBaseRateFromRedemption(totals.totalETHDrawn, price);

        // Calculate the ETH fee
        totals.ETHFee = _getRedemptionFee(totals.totalETHDrawn);
        
        require(_maxFee >= totals.ETHFee || _maxFee == 0, "TroveManager: redemption fee exceeded provided max");

        // Send the ETH fee to the LQTY staking contract
        activePool.sendETH(address(lqtyStaking), totals.ETHFee);
        lqtyStaking.increaseF_ETH(totals.ETHFee);

        totals.ETHToSendToRedeemer = totals.totalETHDrawn.sub(totals.ETHFee);

        emit Redemption(_LUSDamount, totals.totalLUSDToRedeem, totals.totalETHDrawn, totals.ETHFee);

        // Burn the total LUSD that is cancelled with debt, and send the redeemed ETH to msg.sender
        _activePoolRedeemCollateral(msg.sender, totals.totalLUSDToRedeem, totals.ETHToSendToRedeemer);
    }

    // Burn the received LUSD, transfer the redeemed ETH to _redeemer and updates the Active Pool
    function _activePoolRedeemCollateral(address _redeemer, uint _LUSD, uint _ETH) internal {
        // Update Active Pool LUSD, and send ETH to account
        lusdToken.burn(_redeemer, _LUSD);
        activePool.decreaseLUSDDebt(_LUSD);

        activePool.sendETH(_redeemer, _ETH);
    }

    // --- Helper functions ---

    // Return the nominal collateral ratio (ICR) of a given Trove, without the price. Takes a trove's pending coll and debt rewards from redistributions into account.
    function getNominalICR(address _borrower) public view override returns (uint) {
        (uint currentETH, uint currentLUSDDebt) = _getCurrentTroveAmounts(_borrower);

        uint NICR = LiquityMath._computeNominalCR(currentETH, currentLUSDDebt);
        return NICR;
    }

    // Return the current collateral ratio (ICR) of a given Trove. Takes a trove's pending coll and debt rewards from redistributions into account.
    function getCurrentICR(address _borrower, uint _price) public view override returns (uint) {
        (uint currentETH, uint currentLUSDDebt) = _getCurrentTroveAmounts(_borrower);

        uint ICR = LiquityMath._computeCR(currentETH, currentLUSDDebt, _price);
        return ICR;
    }

    function _getCurrentTroveAmounts(address _borrower) internal view returns (uint, uint) {
        uint pendingETHReward = getPendingETHReward(_borrower);
        uint pendingLUSDDebtReward = getPendingLUSDDebtReward(_borrower);

        uint currentETH = Troves[_borrower].coll.add(pendingETHReward);
        uint currentLUSDDebt = Troves[_borrower].debt.add(pendingLUSDDebtReward);

        return (currentETH, currentLUSDDebt);
    }

    function applyPendingRewards(address _borrower) external override {
        _requireCallerIsBorrowerOperations();
        return _applyPendingRewards(_borrower);
    }

    // Add the borrowers's coll and debt rewards earned from redistributions, to their Trove
    function _applyPendingRewards(address _borrower) internal {
        if (hasPendingRewards(_borrower)) {
            _requireTroveisActive(_borrower);

            // Compute pending rewards
            uint pendingETHReward = getPendingETHReward(_borrower);
            uint pendingLUSDDebtReward = getPendingLUSDDebtReward(_borrower);

            // Apply pending rewards to trove's state
            Troves[_borrower].coll = Troves[_borrower].coll.add(pendingETHReward);
            Troves[_borrower].debt = Troves[_borrower].debt.add(pendingLUSDDebtReward);

            _updateTroveRewardSnapshots(_borrower);

            // Transfer from DefaultPool to ActivePool
            _movePendingTroveRewardsToActivePool(pendingLUSDDebtReward, pendingETHReward);

            emit TroveUpdated(
                _borrower,
                Troves[_borrower].debt,
                Troves[_borrower].coll,
                Troves[_borrower].stake,
                TroveManagerOperation.applyPendingRewards
            );
        }
    }

    // Update borrower's snapshots of L_ETH and L_LUSDDebt to reflect the current values
    function updateTroveRewardSnapshots(address _borrower) external override {
        _requireCallerIsBorrowerOperations();
       return _updateTroveRewardSnapshots(_borrower);
    }

    function _updateTroveRewardSnapshots(address _borrower) internal {
        rewardSnapshots[_borrower].ETH = L_ETH;
        rewardSnapshots[_borrower].LUSDDebt = L_LUSDDebt;
    }

    // Get the borrower's pending accumulated ETH reward, earned by their stake
    function getPendingETHReward(address _borrower) public view override returns (uint) {
        uint snapshotETH = rewardSnapshots[_borrower].ETH;
        uint rewardPerUnitStaked = L_ETH.sub(snapshotETH);

        if ( rewardPerUnitStaked == 0 ) { return 0; }

        uint stake = Troves[_borrower].stake;

        uint pendingETHReward = stake.mul(rewardPerUnitStaked).div(DECIMAL_PRECISION);

        return pendingETHReward;
    }

     // Get the borrower's pending accumulated LUSD reward, earned by their stake
    function getPendingLUSDDebtReward(address _borrower) public view override returns (uint) {
        uint snapshotLUSDDebt = rewardSnapshots[_borrower].LUSDDebt;
        uint rewardPerUnitStaked = L_LUSDDebt.sub(snapshotLUSDDebt);

        if ( rewardPerUnitStaked == 0 ) { return 0; }

        uint stake =  Troves[_borrower].stake;

        uint pendingLUSDDebtReward = stake.mul(rewardPerUnitStaked).div(DECIMAL_PRECISION);

        return pendingLUSDDebtReward;
    }

    function hasPendingRewards(address _borrower) public view override returns (bool) {
        /*
        * A Trove has pending rewards if its snapshot is less than the current rewards per-unit-staked sum:
        * this indicates that rewards have occured since the snapshot was made, and the user therefore has
        * pending rewards
        */
        return (rewardSnapshots[_borrower].ETH < L_ETH);
    }

    // Return the Troves entire debt and coll, including pending rewards from redistributions.
    function getEntireDebtAndColl(
        address _borrower
    )
        public
        view
        override
        returns (uint debt, uint coll, uint pendingLUSDDebtReward, uint pendingETHReward)
    {
        debt = Troves[_borrower].debt;
        coll = Troves[_borrower].coll;

        pendingLUSDDebtReward = getPendingLUSDDebtReward(_borrower);
        pendingETHReward = getPendingETHReward(_borrower);

        debt = debt.add(pendingLUSDDebtReward);
        coll = coll.add(pendingETHReward);
    }

    function removeStake(address _borrower) external override {
        _requireCallerIsBorrowerOperations();
        return _removeStake(_borrower);
    }

    // Remove borrower's stake from the totalStakes sum, and set their stake to 0
    function _removeStake(address _borrower) internal {
        uint stake = Troves[_borrower].stake;
        totalStakes = totalStakes.sub(stake);
        Troves[_borrower].stake = 0;
    }

    function updateStakeAndTotalStakes(address _borrower) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        return _updateStakeAndTotalStakes(_borrower);
    }

    // Update borrower's stake based on their latest collateral value
    function _updateStakeAndTotalStakes(address _borrower) internal returns (uint) {
        uint newStake = _computeNewStake(Troves[_borrower].coll);
        uint oldStake = Troves[_borrower].stake;
        Troves[_borrower].stake = newStake;
        totalStakes = totalStakes.sub(oldStake).add(newStake);

        return newStake;
    }

    // Calculate a new stake based on the snapshots of the totalStakes and totalCollateral taken at the last liquidation
    function _computeNewStake(uint _coll) internal view returns (uint) {
        uint stake;
        if (totalCollateralSnapshot == 0) {
            stake = _coll;
        } else {
            /*
            * The following assert() holds true because:
            * - The system always contains >= 1 trove
            * - When we close or liquidate a trove, we redistribute the pending rewards, so if all troves were closed/liquidated,
            * rewards would’ve been emptied and totalCollateralSnapshot would be zero too.
            */
            assert(totalStakesSnapshot > 0);
            stake = _coll.mul(totalStakesSnapshot).div(totalCollateralSnapshot);
        }
        return stake;
    }

    function _redistributeDebtAndColl(uint _debt, uint _coll) internal {
        if (_debt == 0) { return; }

        /*
        * Add distributed coll and debt rewards-per-unit-staked to the running totals. Division uses a "feedback" 
        * error correction, to keep the cumulative error low in the running totals L_ETH and L_LUSDDebt:
        *
        * 1) Form numerators which compensate for the floor division errors that occurred the last time this 
        * function was called.  
        * 2) Calculate "per-unit-staked" ratios.
        * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
        * 4) Store these errors for use in the next correction when this function is called.
        * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
        */
        uint ETHNumerator = _coll.mul(DECIMAL_PRECISION).add(lastETHError_Redistribution);
        uint LUSDDebtNumerator = _debt.mul(DECIMAL_PRECISION).add(lastLUSDDebtError_Redistribution);

        // Get the per-unit-staked terms
        uint ETHRewardPerUnitStaked = ETHNumerator.div(totalStakes);
        uint LUSDDebtRewardPerUnitStaked = LUSDDebtNumerator.div(totalStakes);

        lastETHError_Redistribution = ETHNumerator.sub(ETHRewardPerUnitStaked.mul(totalStakes));
        lastLUSDDebtError_Redistribution = LUSDDebtNumerator.sub(LUSDDebtRewardPerUnitStaked.mul(totalStakes));

        // Add per-unit-staked terms to the running totals
        L_ETH = L_ETH.add(ETHRewardPerUnitStaked);
        L_LUSDDebt = L_LUSDDebt.add(LUSDDebtRewardPerUnitStaked);

        // Transfer coll and debt from ActivePool to DefaultPool
        activePool.decreaseLUSDDebt(_debt);
        defaultPool.increaseLUSDDebt(_debt);
        activePool.sendETH(address(defaultPool), _coll);
    }

    function closeTrove(address _borrower) external override {
        _requireCallerIsBorrowerOperations();
        return _closeTrove(_borrower);
    }

    function _closeTrove(address _borrower) internal {
        uint TroveOwnersArrayLength = TroveOwners.length;
        _requireMoreThanOneTroveInSystem(TroveOwnersArrayLength);

        Troves[_borrower].status = Status.closed;
        Troves[_borrower].coll = 0;
        Troves[_borrower].debt = 0;

        rewardSnapshots[_borrower].ETH = 0;
        rewardSnapshots[_borrower].LUSDDebt = 0;

        _removeTroveOwner(_borrower, TroveOwnersArrayLength);
        sortedTroves.remove(_borrower);
    }

    /*
    * Updates snapshots of system total stakes and total collateral, excluding a given collateral remainder from the calculation.
    * Used in a liquidation sequence.
    *
    * The calculation excludes a portion of collateral that is in the ActivePool:
    *
    * the total ETH gas compensation from the liquidation sequence
    *
    * The ETH as compensation must be excluded as it is always sent out at the very end of the liquidation sequence.
    */
    function _updateSystemSnapshots_excludeCollRemainder(uint _collRemainder) internal {
        totalStakesSnapshot = totalStakes;

        uint activeColl = activePool.getETH();
        uint liquidatedColl = defaultPool.getETH();
        totalCollateralSnapshot = activeColl.sub(_collRemainder).add(liquidatedColl);
    }

    // Push the owner's address to the Trove owners list, and record the corresponding array index on the Trove struct
    function addTroveOwnerToArray(address _borrower) external override returns (uint index) {
        _requireCallerIsBorrowerOperations();
        return _addTroveOwnerToArray(_borrower);
    }

    function _addTroveOwnerToArray(address _borrower) internal returns (uint128 index) {
        /* Max array size is 2**128 - 1, i.e. ~3e30 troves. No risk of overflow, since troves have minimum 10 LUSD
        debt. 3e31 LUSD dwarfs the value of all wealth in the world ( which is < 1e15 USD). */

        // Push the Troveowner to the array
        TroveOwners.push(_borrower);

        // Record the index of the new Troveowner on their Trove struct
        index = uint128(TroveOwners.length.sub(1));
        Troves[_borrower].arrayIndex = index;

        return index;
    }

    /*
    * Remove a Trove owner from the TroveOwners array, not preserving array order. Removing owner 'B' does the following:
    * [A B C D E] => [A E C D], and updates E's Trove struct to point to its new array index.
    */
    function _removeTroveOwner(address _borrower, uint TroveOwnersArrayLength) internal {
        // It’s set in caller function `_closeTrove`
        assert(Troves[_borrower].status == Status.closed);

        uint128 index = Troves[_borrower].arrayIndex;
        uint length = TroveOwnersArrayLength;
        uint idxLast = length.sub(1);

        assert(index <= idxLast);

        address addressToMove = TroveOwners[idxLast];

        TroveOwners[index] = addressToMove;
        Troves[addressToMove].arrayIndex = index;
        TroveOwners.pop();
    }

    // --- Recovery Mode and TCR functions ---

    function getTCR() external view override returns (uint) {
        return _getTCR();
    }

    function checkRecoveryMode() external view override returns (bool) {
        return _checkRecoveryMode();
    }

    // Check whether or not the system *would be* in Recovery Mode, given an ETH:USD price, and the entire system coll and debt.
    function _checkPotentialRecoveryMode(
        uint _entireSystemColl,
        uint _entireSystemDebt,
        uint _price
    )
        internal
        pure
    returns (bool)
    {
        uint TCR = LiquityMath._computeCR(_entireSystemColl, _entireSystemDebt, _price);

        return TCR < CCR;
    }

    // --- Redemption fee functions ---

    /*
    * This function has two impacts on the baseRate state variable:
    * 1) decays the baseRate based on time passed since last redemption or LUSD borrowing operation.
    * then,
    * 2) increases the baseRate based on the amount redeemed, as a proportion of total supply
    */
    function _updateBaseRateFromRedemption(uint _ETHDrawn,  uint _price) internal returns (uint) {
        uint decayedBaseRate = _calcDecayedBaseRate();

        uint activeDebt = activePool.getLUSDDebt();
        uint closedDebt = defaultPool.getLUSDDebt();
        uint totalLUSDSupply = activeDebt.add(closedDebt);

        /* Convert the drawn ETH back to LUSD at face value rate (1 LUSD:1 USD), in order to get
        * the fraction of total supply that was redeemed at face value. */
        uint redeemedLUSDFraction = _ETHDrawn.mul(_price).div(totalLUSDSupply);

        uint newBaseRate = decayedBaseRate.add(redeemedLUSDFraction.div(BETA));
        newBaseRate = LiquityMath._min(newBaseRate, DECIMAL_PRECISION); // cap baseRate at a maximum of 100%
        //assert(newBaseRate <= DECIMAL_PRECISION); // This is already enforced in the line above
        assert(newBaseRate > 0); // Base rate is always non-zero after redemption

        // Update the baseRate state variable
        baseRate = newBaseRate;

        _updateLastFeeOpTime();

        return newBaseRate;
    }

    function _getRedemptionFee(uint _ETHDrawn) internal view returns (uint) {
       return baseRate.mul(_ETHDrawn).div(DECIMAL_PRECISION);
    }

    // --- Borrowing fee functions ---

    function getBorrowingFee(uint _LUSDDebt) external view override returns (uint) {
        return _LUSDDebt.mul(baseRate).div(DECIMAL_PRECISION);
    }

    // Updates the baseRate state variable based on time elapsed since the last redemption or LUSD borrowing operation.
    function decayBaseRateFromBorrowing() external override {
        _requireCallerIsBorrowerOperations();

        uint decayedBaseRate = _calcDecayedBaseRate();
        assert(decayedBaseRate <= DECIMAL_PRECISION);  // The baseRate can decay to 0

        baseRate = decayedBaseRate;

        _updateLastFeeOpTime();
    }

    // --- Internal fee functions ---

    // Update the last fee operation time only if time passed >= decay interval. This prevents base rate griefing.
    function _updateLastFeeOpTime() internal {
        uint timePassed = block.timestamp.sub(lastFeeOperationTime);

        if (timePassed >= SECONDS_IN_ONE_MINUTE) {
            lastFeeOperationTime = block.timestamp;
        }
    }

    function _calcDecayedBaseRate() internal view returns (uint) {
        uint minutesPassed = _minutesPassedSinceLastFeeOp();
        uint decayFactor = LiquityMath._decPow(MINUTE_DECAY_FACTOR, minutesPassed);

        return baseRate.mul(decayFactor).div(DECIMAL_PRECISION);
    }

    function _minutesPassedSinceLastFeeOp() internal view returns (uint) {
        return (block.timestamp.sub(lastFeeOperationTime)).div(SECONDS_IN_ONE_MINUTE);
    }

    // --- 'require' wrapper functions ---

    function _requireCallerIsBorrowerOperations() internal view {
        require(msg.sender == borrowerOperationsAddress, "TroveManager: Caller is not the BorrowerOperations contract");
    }

    function _requireTroveisActive(address _borrower) internal view {
        require(Troves[_borrower].status == Status.active, "TroveManager: Trove does not exist or is closed");
    }

    function _requireLUSDBalanceCoversRedemption(address _redeemer, uint _amount) internal view {
        require(lusdToken.balanceOf(_redeemer) >= _amount, "TroveManager: Requested redemption amount must be <= user's LUSD token balance");
    }

    function _requireMoreThanOneTroveInSystem(uint TroveOwnersArrayLength) internal view {
        require (TroveOwnersArrayLength > 1 && sortedTroves.getSize() > 1, "TroveManager: Only one trove in the system");
    }

    function _requireAmountGreaterThanZero(uint _amount) internal pure {
        require(_amount > 0, "TroveManager: Amount must be greater than zero");
    }

    function _requireTCRoverMCR() internal view {
        require(_getTCR() >= MCR, "TroveManager: Cannot redeem when TCR < MCR");
    }

    // --- Trove property getters ---

    function getTroveStatus(address _borrower) external view override returns (uint) {
        return uint(Troves[_borrower].status);
    }

    function getTroveStake(address _borrower) external view override returns (uint) {
        return Troves[_borrower].stake;
    }

    function getTroveDebt(address _borrower) external view override returns (uint) {
        return Troves[_borrower].debt;
    }

    function getTroveColl(address _borrower) external view override returns (uint) {
        return Troves[_borrower].coll;
    }

    // --- Trove property setters, called by BorrowerOperations ---

    function setTroveStatus(address _borrower, uint _num) external override {
        _requireCallerIsBorrowerOperations();
        Troves[_borrower].status = Status(_num);
    }

    function increaseTroveColl(address _borrower, uint _collIncrease) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        uint newColl = Troves[_borrower].coll.add(_collIncrease);
        Troves[_borrower].coll = newColl;
        return newColl;
    }

    function decreaseTroveColl(address _borrower, uint _collDecrease) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        uint newColl = Troves[_borrower].coll.sub(_collDecrease);
        Troves[_borrower].coll = newColl;
        return newColl;
    }

    function increaseTroveDebt(address _borrower, uint _debtIncrease) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        uint newDebt = Troves[_borrower].debt.add(_debtIncrease);
        Troves[_borrower].debt = newDebt;
        return newDebt;
    }

    function decreaseTroveDebt(address _borrower, uint _debtDecrease) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        uint newDebt = Troves[_borrower].debt.sub(_debtDecrease);
        Troves[_borrower].debt = newDebt;
        return newDebt;
    }
}