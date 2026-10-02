use std::{path::PathBuf, process::Command};

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("quotio-proxy-cli-{}", std::process::id()));
        std::fs::create_dir_all(root.join("auth")).unwrap();
        let root = root.canonicalize().unwrap();
        std::fs::write(root.join("quotio.toml"), "enabled_providers = []\n").unwrap();
        std::fs::write(root.join("auth/expired.json"), br#"{"type":"codex","account_id":"account-fixture","email":"work@example.test","access_token":"access-secret-sentinel","refresh_token":"refresh-secret-sentinel","expired":"2020-01-01T00:00:00Z"}"#).unwrap();
        std::fs::write(
            root.join("auth/disabled.json"),
            br#"{"type":"claude","disabled":true,"access_token":"disabled-secret-sentinel"}"#,
        )
        .unwrap();
        std::fs::write(
            root.join("proxy.yaml"),
            br#"
api-keys: [proxy-client-secret-sentinel]
openai-compatibility:
  - name: Work
    base-url: https://openrouter.ai/api/v1
    disabled: true
    api-key-entries: [{api-key: provider-secret-sentinel}]
  - name: openrouter
    base-url: https://unrecognized.example/v1
    api-key-entries: [{api-key: unsupported-secret-sentinel}]
"#,
        )
        .unwrap();
        Self(root)
    }

    fn usage(&self, extra: &[&str]) -> std::process::Output {
        Command::new(env!("CARGO_BIN_EXE_quotio"))
            .env_clear()
            .env("HOME", &self.0)
            .env("PATH", &self.0)
            .env("QUOTIO_CACHE_DIR", self.0.join("cache"))
            .args([
                "usage",
                "--no-saved-accounts",
                "--format",
                "json",
                "--force",
                "--timeout",
                "1",
                "--config",
            ])
            .arg(self.0.join("quotio.toml"))
            .arg("--cli-proxy-auth-dir")
            .arg(self.0.join("auth"))
            .arg("--cli-proxy-config")
            .arg(self.0.join("proxy.yaml"))
            .args(extra)
            .output()
            .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn cli_keeps_disabled_and_expired_proxy_accounts_visible_without_writes_or_secret_output() {
    let fixture = Fixture::new();
    let paths = ["auth/expired.json", "auth/disabled.json", "proxy.yaml"];
    let before = paths.map(|path| std::fs::read(fixture.0.join(path)).unwrap());
    let output = fixture.usage(&[
        "--provider",
        "codex",
        "--provider",
        "claude",
        "--provider",
        "openrouter",
    ]);
    assert_eq!(output.status.code(), Some(3));
    let snapshot: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    let accounts = snapshot["accounts"].as_array().unwrap();
    assert_eq!(accounts.len(), 3);
    for account in accounts {
        assert_eq!(account["sources"][0]["origin"], "borrowed_proxy");
        assert!(account["actions"].as_array().unwrap().is_empty());
        assert!(
            account["sources"][0]["actions"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }
    let codex = accounts
        .iter()
        .find(|account| account["provider_id"] == "codex")
        .unwrap();
    assert_eq!(codex["state"], "needs_login");
    let usage = snapshot["usage"]
        .as_array()
        .unwrap()
        .iter()
        .find(|usage| usage["account_id"] == codex["id"])
        .unwrap();
    assert_eq!(usage["issue"]["code"], "owner_refresh_required");
    assert_eq!(usage["issue"]["action"]["kind"], "refresh_in_source_app");
    assert!(usage["metrics"].as_array().unwrap().is_empty());
    for account in accounts
        .iter()
        .filter(|account| account["provider_id"] != "codex")
    {
        assert_eq!(account["state"], "disabled");
        assert_eq!(account["enabled"], false);
    }
    assert!(String::from_utf8_lossy(&output.stderr).contains("no supported quota API"));
    assert!(!String::from_utf8_lossy(&output.stdout).contains("secret-sentinel"));
    assert!(!String::from_utf8_lossy(&output.stderr).contains("secret-sentinel"));

    let scoped = fixture.usage(&[
        "--provider",
        "codex",
        "--account",
        codex["id"].as_str().unwrap(),
    ]);
    assert_eq!(scoped.status.code(), Some(3));
    let scoped: serde_json::Value = serde_json::from_slice(&scoped.stdout).unwrap();
    assert_eq!(scoped["accounts"].as_array().unwrap().len(), 1);
    assert_eq!(scoped["accounts"][0]["id"], codex["id"]);

    let invalid_scope = fixture.usage(&[
        "--provider",
        "codex",
        "--provider",
        "claude",
        "--account",
        codex["id"].as_str().unwrap(),
    ]);
    assert_eq!(invalid_scope.status.code(), Some(2));
    assert!(invalid_scope.stdout.is_empty());

    std::fs::write(
        fixture.0.join("proxy.yaml"),
        b"openai-compatibility: [ secret-sentinel",
    )
    .unwrap();
    let invalid = fixture.usage(&["--provider", "openrouter"]);
    assert_eq!(invalid.status.code(), Some(2));
    assert!(!String::from_utf8_lossy(&invalid.stderr).contains("secret-sentinel"));
    std::fs::write(fixture.0.join("proxy.yaml"), &before[2]).unwrap();
    for (path, bytes) in paths.into_iter().zip(before) {
        assert_eq!(std::fs::read(fixture.0.join(path)).unwrap(), bytes);
    }
}
