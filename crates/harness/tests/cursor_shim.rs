//! Execute the production JavaScript shim with a synthetic SDK. A shell shim
//! cannot catch Node dropping buffered stdout during process.exit().
use std::process::Stdio;

async fn run_shim(sdk: &str, mode: &str) -> std::process::Output {
    let dir = tempfile::tempdir().unwrap();
    let package = dir.path().join("node_modules/@cursor/sdk");
    std::fs::create_dir_all(&package).unwrap();
    std::fs::write(
        package.join("package.json"),
        r#"{"type":"module","exports":"./index.mjs"}"#,
    )
    .unwrap();
    std::fs::write(package.join("index.mjs"), sdk).unwrap();
    let shim = dir.path().join("shim.mjs");
    std::fs::write(&shim, include_str!("../src/cursor/shim.mjs")).unwrap();
    tokio::time::timeout(
        std::time::Duration::from_secs(10),
        tokio::process::Command::new("node")
            .arg(shim)
            .arg(mode)
            .arg(dir.path().join("auth.json"))
            .stdin(Stdio::null())
            .kill_on_drop(true)
            .output(),
    )
    .await
    .expect("shim must exit despite SDK background handles")
    .expect("Node is required to exercise the Cursor shim")
}

#[tokio::test]
async fn large_catalog_is_fully_flushed_before_exit() {
    let output = run_shim(
        r#"
        setInterval(() => {}, 1000);
        export const Cursor = { models: { list: async () => Array.from(
          {length: 4096}, (_, i) => ({id: `model-${i}`, displayName: '模型 ' + i,
          description: 'x'.repeat(1024), parameters: [], variants: []})
        ) } };
        "#,
        "models",
    )
    .await;
    assert!(output.status.success());
    assert!(output.stdout.len() > 4 * 1024 * 1024);
    let frame: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(frame["ev"], "models");
    assert_eq!(frame["items"].as_array().unwrap().len(), 4096);
    assert_eq!(frame["items"][4095]["id"], "model-4095");
}

#[tokio::test]
async fn large_fatal_frame_is_fully_flushed_and_exits_unsuccessfully() {
    let output = run_shim(
        r#"export const Cursor = { models: { list: async () => {
          throw new Error('x'.repeat(1024 * 1024));
        } } };"#,
        "models",
    )
    .await;
    assert!(!output.status.success());
    let frame: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(frame["ev"], "fatal");
    assert!(frame["message"].as_str().unwrap().len() > 1024 * 1024);
}

#[tokio::test]
async fn login_frames_are_flushed_before_exit() {
    let output = run_shim(
        r#"
        export class FileCredentialStore { constructor(path) {} }
        export const Cursor = { auth: { login: async ({onLoginUrl}) => {
          onLoginUrl('https://example.test/' + 'x'.repeat(1024 * 1024));
          return {email: 'test@example.test'};
        } } };
        "#,
        "login",
    )
    .await;
    assert!(output.status.success());
    let frames: Vec<serde_json::Value> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0]["ev"], "auth-url");
    assert_eq!(frames[1]["ev"], "logged-in");
}
