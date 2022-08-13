use candid::CandidType;
use ic_certified_map::{labeled, labeled_hash, AsHashTree, Hash, RbTree};
use serde::Deserialize;
use serde::Serialize;
use serde_bytes::ByteBuf;
use sha2::{Digest, Sha256};
use std::collections::HashMap;

type Headers = Vec<(String, String)>;

const LABEL: &[u8] = b"http_assets";
static mut ASSET_HASHES: Option<RbTree<Vec<u8>, Hash>> = None;
static mut ASSETS: Option<HashMap<String, (Headers, Vec<u8>)>> = None;

fn asset_hashes<'a>() -> &'a mut RbTree<Vec<u8>, Hash> {
    unsafe { ASSET_HASHES.as_mut().expect("uninitialized") }
}

fn assets<'a>() -> &'a mut HashMap<String, (Headers, Vec<u8>)> {
    unsafe { ASSETS.as_mut().expect("uninitialized") }
}

pub fn load() {
    unsafe {
        ASSET_HASHES = Some(Default::default());
        ASSETS = Some(Default::default());
    }

    add_asset(
        &["/", "/index.html"],
        vec![(
            "Content-Type".to_string(),
            "text/html; charset=UTF-8".to_string(),
        )],
        include_bytes!("../../build/index.html").to_vec(),
    );

    add_asset(
        &["/favicon.png"],
        vec![
            ("Content-Type".to_string(), "image/png".to_string()),
            ("Cache-Control".to_string(), "public".to_string()),
        ],
        include_bytes!("../../build/favicon.png").to_vec(),
    );

    add_asset(
        &["/lusd-icon.png", "/logo256.png"],
        vec![
            ("Content-Type".to_string(), "image/png".to_string()),
            ("Cache-Control".to_string(), "public".to_string()),
        ],
        include_bytes!("../../build/lusd-icon.png").to_vec(),
    );

    add_asset(
        &["/static/js/main.fe29b6d3.chunk.js"],
        vec![
            ("Content-Type".to_string(), "text/javascript".to_string()),
            ("Content-Encoding".to_string(), "gzip".to_string()),
            ("Cache-Control".to_string(), "public".to_string()),
        ],
        include_bytes!("../../build/static/js/main.fe29b6d3.chunk.js.gzip").to_vec(),
    );

    add_asset(
        &["/static/js/runtime-main.e8ec8050.js"],
        vec![
            ("Content-Type".to_string(), "text/javascript".to_string()),
            ("Content-Encoding".to_string(), "gzip".to_string()),
            ("Cache-Control".to_string(), "public".to_string()),
        ],
        include_bytes!("../../build/static/js/runtime-main.e8ec8050.js.gzip").to_vec(),
    );

    add_asset(
        &["/static/js/2.8dcf0a4b.chunk.js"],
        vec![
            ("Content-Type".to_string(), "text/javascript".to_string()),
            ("Content-Encoding".to_string(), "gzip".to_string()),
            ("Cache-Control".to_string(), "public".to_string()),
        ],
        include_bytes!("../../build/static/js/2.8dcf0a4b.chunk.js.gzip").to_vec(),
    );

    add_asset(
        &["/static/css/2.bf1df848.chunk.css"],
        vec![
            ("Content-Type".to_string(), "text/css".to_string()),
            ("Content-Encoding".to_string(), "gzip".to_string()),
            ("Cache-Control".to_string(), "public".to_string()),
        ],
        include_bytes!("../../build/static/css/2.bf1df848.chunk.css.gzip").to_vec(),
    );

    add_asset(
        &["/config.json"],
        vec![
            ("Content-Type".to_string(), "application/json".to_string()),
            ("Cache-Control".to_string(), "public".to_string()),
        ],
        include_bytes!("../../build/config.json").to_vec(),
    );

    add_asset(
        &["/static/css/main.bfb92520.chunk.css"],
        vec![
            ("Content-Type".to_string(), "text/css".to_string()),
            ("Content-Encoding".to_string(), "gzip".to_string()),
        ],
        include_bytes!("../../build/static/css/main.bfb92520.chunk.css.gzip").to_vec(),
    );

    ic_cdk::api::set_certified_data(&labeled_hash(LABEL, &asset_hashes().root_hash()));
}

fn add_asset(paths: &[&str], headers: Headers, bytes: Vec<u8>) {
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    let hash = hasher.finalize().into();
    for path in paths {
        asset_hashes().insert(path.as_bytes().to_vec(), hash);
        assets().insert(path.to_string(), (headers.clone(), bytes.clone()));
    }
}

#[derive(CandidType, Deserialize)]
pub struct HttpRequest {
    url: String,
}

#[derive(CandidType, Serialize)]
pub struct HttpResponse {
    status_code: u16,
    headers: Headers,
    body: ByteBuf,
}

#[ic_cdk_macros::query]
fn http_request(req: HttpRequest) -> HttpResponse {
    let path = req.url.split("?").next().expect("no path in url");
    response(path)
}

fn response(path: &str) -> HttpResponse {
    let (headers, bytes) = assets()
        .get(path)
        .expect(format!("no asset {:?}", path).as_str());
    let mut headers = headers.clone();
    headers.push(certificate_header(path));
    HttpResponse {
        status_code: 200,
        headers,
        body: ByteBuf::from(bytes.as_slice()),
    }
}

fn certificate_header(path: &str) -> (String, String) {
    let certificate = ic_cdk::api::data_certificate().expect("no certificate");
    let witness = asset_hashes().witness(path.as_bytes());
    let tree = labeled(LABEL, witness);
    let mut serializer = serde_cbor::ser::Serializer::new(Vec::new());
    serializer.self_describe().expect("tagging failed");
    tree.serialize(&mut serializer).expect("couldn't serialize");
    (
        "IC-Certificate".to_string(),
        format!(
            "certificate=:{}:, tree=:{}:",
            base64::encode(&certificate),
            base64::encode(&serializer.into_inner())
        ),
    )
}