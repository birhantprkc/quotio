//! Provider inference keys are distinct from CLIProxyAPI's client access keys.
use super::*;

struct Entry {
    provider: Provider,
    reference: AccountRef,
    keys: HashMap<String, String>,
    disabled: bool,
}

pub(super) fn adapters(
    path: &Path,
    providers: &[Provider],
    account: Option<&str>,
) -> Result<Vec<Arc<dyn ProviderAdapter>>, AccountError> {
    validate_directory(path.parent().ok_or(AccountError::Input)?)?;
    match std::fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        _ => (),
    }
    let bytes = read_file(path).map_err(|_| AccountError::Storage)?;
    Ok(entries(path, &bytes)
        .map_err(|_| AccountError::Input)?
        .into_iter()
        .filter(|entry| providers.contains(&entry.provider))
        .filter(|entry| {
            account.is_none_or(|id| {
                id == entry.reference.id
                    || id
                        == crate::contract::snapshot::external_id(
                            entry.provider.id(),
                            Some(&entry.reference),
                        )
            })
        })
        .map(|entry| {
            Arc::new(BorrowedProxyProvider {
                path: path.into(),
                provider: entry.provider,
                reference: entry.reference,
                config_key: true,
            }) as Arc<dyn ProviderAdapter>
        })
        .collect())
}

pub(super) fn snapshot(
    path: &Path,
    id: &str,
    provider: Provider,
) -> Result<Snapshot, ProviderError> {
    let bytes = read_file(path)?;
    // ponytail: reparse a bounded config per key; share parsed snapshots if 512 keys become slow.
    let entry = entries(path, &bytes)?
        .into_iter()
        .find(|entry| entry.reference.id == id && entry.provider == provider)
        .ok_or(ProviderError::Transient)?;
    if entry.disabled {
        return Err(ProviderError::SourceDisabled);
    }
    Ok(Snapshot {
        digest: crate::cache::fingerprint(&[
            "cli_proxy_api_key",
            id,
            &String::from_utf8_lossy(&bytes),
        ]),
        material: Material::Keys(entry.keys),
    })
}

fn entries(path: &Path, bytes: &[u8]) -> Result<Vec<Entry>, ProviderError> {
    let options = serde_saphyr::options! {
        budget: serde_saphyr::budget! {
            max_depth: 64,
            max_nodes: 32_768,
            max_events: 32_768,
            max_total_scalar_bytes: 2 * MAX_FILE_BYTES as usize,
            max_aliases: 128,
            max_anchors: 128,
            max_documents: 1,
        },
        alias_limits: serde_saphyr::alias_limits! {
            max_total_replayed_events: 32_768,
            max_replay_stack_depth: 16,
        },
    };
    let root: Value = serde_saphyr::from_slice_with_options(bytes, options)
        .map_err(|_| ProviderError::InvalidData)?;
    if !root.is_object() {
        return Err(ProviderError::InvalidData);
    }
    let mut entries = Vec::new();
    let mut count = 0;
    let mut unsupported = 0;
    for (section, groups) in [
        ("codex-api-key", root.get("codex-api-key")),
        ("claude-api-key", root.get("claude-api-key")),
        ("gemini-api-key", root.get("gemini-api-key")),
        ("vertex-api-key", root.get("vertex-api-key")),
        ("openai-compatibility", root.get("openai-compatibility")),
        ("v8-codex", root.pointer("/api-keys/codex")),
        ("v8-claude", root.pointer("/api-keys/claude")),
        ("v8-gemini", root.pointer("/api-keys/gemini")),
        ("v8-vertex", root.pointer("/api-keys/vertex")),
        ("v8-openai", root.pointer("/api-keys/openai-compatibility")),
    ] {
        let Some(groups) = groups.filter(|value| !value.is_null()) else {
            continue;
        };
        let groups = groups.as_array().ok_or(ProviderError::InvalidData)?;
        if groups.len() > MAX_FILES {
            return Err(ProviderError::InvalidData);
        }
        for (group_index, group) in groups.iter().enumerate() {
            let keys =
                if let Some(keys) = group.get("keys").or_else(|| group.get("api-key-entries")) {
                    keys.as_array()
                        .ok_or(ProviderError::InvalidData)?
                        .as_slice()
                } else {
                    std::slice::from_ref(group)
                };
            for (key_index, key) in keys.iter().enumerate() {
                count += 1;
                if count > MAX_FILES {
                    return Err(ProviderError::InvalidData);
                }
                let Some((provider, region)) = text(group, &["base-url"]).and_then(key_provider)
                else {
                    unsupported += 1;
                    continue;
                };
                let token = text(key, &["api-key"]).ok_or(ProviderError::InvalidData)?;
                let mut credentials = HashMap::from([(
                    provider
                        .api_key_name()
                        .expect("inference key provider")
                        .into(),
                    token.into(),
                )]);
                if let Some((name, value)) = region {
                    credentials.insert(name.into(), value.into());
                }
                let id = format!(
                    "proxy-key-{}",
                    crate::cache::fingerprint(&[
                        "cli_proxy_api_key",
                        provider.id(),
                        path.to_str().ok_or(ProviderError::InvalidData)?,
                        section,
                        &group_index.to_string(),
                        &key_index.to_string(),
                    ])
                );
                let label = text(group, &["name"])
                    .filter(|name| valid(name, 256))
                    .unwrap_or(provider.id());
                entries.push(Entry {
                    provider,
                    reference: AccountRef {
                        id,
                        origin: Some(AccountOrigin::BorrowedProxy),
                        label: format!("{label} · CLIProxyAPI key {}", key_index + 1),
                    },
                    keys: credentials,
                    disabled: disabled(group)? || disabled(key)?,
                });
            }
        }
    }
    if unsupported > 0 {
        tracing::warn!(
            count = unsupported,
            "Skipped CLIProxyAPI provider keys with no supported quota API"
        );
    }
    Ok(entries)
}

/// Match official origins, never names supplied by the config or arbitrary proxy hosts.
fn key_provider(base: &str) -> Option<(Provider, Option<(&'static str, &'static str)>)> {
    let url = reqwest::Url::parse(base).ok()?;
    if url.scheme() != "https"
        || url.port().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return None;
    }
    Some(match url.host_str()? {
        "openrouter.ai" => (Provider::OpenRouter, None),
        "api.synthetic.new" => (Provider::Synthetic, None),
        "api.z.ai" => (Provider::Zai, Some(("ZAI_REGION", "global"))),
        "open.bigmodel.cn" => (Provider::Zai, Some(("ZAI_REGION", "cn"))),
        "api.minimax.io" => (Provider::MiniMax, Some(("MINIMAX_REGION", "global"))),
        "api.minimaxi.com" | "api.minimax.chat" => {
            (Provider::MiniMax, Some(("MINIMAX_REGION", "cn")))
        }
        "api.deepseek.com" => (Provider::Catalog("deepseek"), None),
        "api.moonshot.ai" => (
            Provider::Catalog("moonshot"),
            Some(("MOONSHOT_REGION", "global")),
        ),
        "api.moonshot.cn" => (
            Provider::Catalog("moonshot"),
            Some(("MOONSHOT_REGION", "cn")),
        ),
        "api.venice.ai" => (Provider::Catalog("venice"), None),
        "api.poe.com" => (Provider::Catalog("poe"), None),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_legacy_and_v8_keys_without_confusing_proxy_access_or_provider_names() {
        let yaml = br#"
api-keys: [proxy-client-secret]
openai-compatibility:
  - name: claude
    base-url: https://openrouter.ai/api/v1
    api-key-entries:
      - api-key: quota-key-a
      - api-key: quota-key-b
        disabled: true
  - name: openrouter
    base-url: https://evil.example/openrouter.ai
    api-key-entries: [{api-key: never-send}]
codex-api-key: [{api-key: inference-only}]
"#;
        let parsed = entries(Path::new("/safe/config.yaml"), yaml).unwrap();
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].provider, Provider::OpenRouter);
        assert_eq!(parsed[0].keys["OPENROUTER_API_KEY"], "quota-key-a");
        assert!(!parsed[0].disabled);
        assert!(parsed[1].disabled);
        assert_ne!(parsed[0].reference.id, parsed[1].reference.id);
        assert!(!parsed[0].reference.id.contains("quota-key"));

        let parsed = entries(
            Path::new("/safe/config.yaml"),
            br#"
config-version: 8
access: {api-keys: [client-secret]}
api-keys:
  openai-compatibility:
    - name: GLM
      disabled: true
      base-url: https://open.bigmodel.cn/api/coding/paas/v4
      keys: [{api-key: china-key}]
    - name: Kimi
      base-url: https://api.moonshot.ai/v1
      keys: [{api-key: global-key}]
"#,
        )
        .unwrap();
        assert_eq!(parsed.len(), 2);
        assert!(parsed[0].disabled);
        assert_eq!(parsed[0].keys["ZAI_REGION"], "cn");
        assert_eq!(parsed[1].keys["MOONSHOT_REGION"], "global");
        for base in [
            "http://openrouter.ai",
            "https://openrouter.ai.evil.example",
            "https://openrouter.ai:8443",
            "https://user@openrouter.ai",
            "https://openrouter.ai?secret=x",
        ] {
            assert!(key_provider(base).is_none());
        }
    }

    #[test]
    fn rejects_malformed_deep_duplicate_and_oversized_yaml_without_echoing_secrets() {
        for yaml in [
            "openai-compatibility: secret-sentinel".to_owned(),
            "openai-compatibility: [\nsecret-sentinel".into(),
            "openai-compatibility: []\nopenai-compatibility: []".into(),
            format!("nest: {}0{}", "[".repeat(100), "]".repeat(100)),
            format!("openai-compatibility: [{}]", "{},".repeat(MAX_FILES + 1)),
        ] {
            let error = entries(Path::new("/safe/config.yaml"), yaml.as_bytes())
                .err()
                .unwrap();
            assert_eq!(error, ProviderError::InvalidData);
            assert!(!error.to_string().contains("secret-sentinel"));
        }
    }

    #[tokio::test]
    async fn borrowed_key_uses_real_quota_adapter_and_tracks_owner_rotation_without_writes() {
        use std::io::{Read, Write};
        use std::time::{Duration, Instant};

        fn headers(stream: &mut impl Read) -> String {
            let mut bytes = Vec::new();
            while !bytes.ends_with(b"\r\n\r\n") {
                assert!(bytes.len() < 8192);
                let mut byte = [0];
                stream.read_exact(&mut byte).unwrap();
                bytes.push(byte[0]);
            }
            String::from_utf8(bytes).unwrap()
        }

        let rcgen::CertifiedKey { cert, signing_key } =
            rcgen::generate_simple_self_signed(vec!["openrouter.ai".into()]).unwrap();
        let tls = rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(
            vec![cert.der().clone()],
            rustls::pki_types::PrivatePkcs8KeyDer::from(signing_key.serialize_der()).into(),
        )
        .unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let proxy = format!("http://{}", listener.local_addr().unwrap());
        let worker = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut requests = Vec::new();
            while requests.len() < 2 {
                assert!(
                    Instant::now() < deadline,
                    "quota requests did not reach fixture"
                );
                let Ok((mut socket, _)) = listener.accept() else {
                    std::thread::sleep(Duration::from_millis(5));
                    continue;
                };
                socket.set_nonblocking(false).unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                socket
                    .set_write_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                assert!(headers(&mut socket).starts_with("CONNECT openrouter.ai:443 "));
                socket
                    .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
                    .unwrap();
                let mut stream = rustls::StreamOwned::new(
                    rustls::ServerConnection::new(Arc::new(tls.clone())).unwrap(),
                    socket,
                );
                let request = headers(&mut stream);
                assert!(
                    request
                        .to_lowercase()
                        .contains("authorization: bearer quota-fixture-key")
                );
                let body = if request.starts_with("GET /api/v1/credits ") {
                    r#"{"data":{"total_credits":100,"total_usage":23}}"#
                } else {
                    assert!(request.starts_with("GET /api/v1/key "));
                    r#"{"data":{"limit":40,"limit_remaining":10,"usage":30,"is_free_tier":false}}"#
                };
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
                stream.flush().unwrap();
                requests.push(request);
            }
            requests
        });
        let directory = super::super::tests::directory();
        let path = directory.join("config.yaml");
        let bytes = b"openai-compatibility:\n  - base-url: https://openrouter.ai/api/v1\n    api-key-entries: [{api-key: quota-fixture-key}]\n";
        std::fs::write(&path, bytes).unwrap();
        let source = adapters(&path, &[Provider::OpenRouter], None)
            .unwrap()
            .remove(0);
        let context = ProviderContext {
            http: reqwest::Client::builder()
                .proxy(reqwest::Proxy::https(proxy).unwrap())
                .add_root_certificate(reqwest::Certificate::from_der(cert.der()).unwrap())
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .unwrap(),
            clock: Arc::new(crate::providers::SystemClock),
            credentials: Arc::new(Keys(HashMap::from([(
                "OPENROUTER_API_KEY".into(),
                "wrong-environment-key".into(),
            )]))),
        };
        let identity = source.cache_identity(&context).await.unwrap();
        let usage = source.fetch(&context).await.unwrap();
        assert_eq!(usage.windows[0].amounts.as_ref().unwrap().remaining, 77.0);
        let spending = usage
            .windows
            .iter()
            .find(|window| window.label == "Key spending limit")
            .unwrap();
        assert_eq!(spending.amounts.as_ref().unwrap().remaining, 10.0);
        assert_eq!(spending.amounts.as_ref().unwrap().limit, Some(40.0));
        assert!(usage.diagnostics.is_empty());
        assert_eq!(worker.join().unwrap().len(), 2);
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        let id = source.account_ref().unwrap().id;
        let rotated = String::from_utf8(bytes.to_vec())
            .unwrap()
            .replace("quota-fixture-key", "rotated-fixture-key");
        std::fs::write(&path, rotated.as_bytes()).unwrap();
        assert_ne!(source.cache_identity(&context).await.unwrap(), identity);
        assert_eq!(
            adapters(&path, &[Provider::OpenRouter], None).unwrap()[0]
                .account_ref()
                .unwrap()
                .id,
            id
        );
        std::fs::write(
            &path,
            rotated.replace("base-url:", "disabled: true\n    base-url:"),
        )
        .unwrap();
        assert!(source.cache_identity(&context).await.is_none());
        assert_eq!(
            source.fetch(&context).await.err(),
            Some(ProviderError::SourceDisabled)
        );
        #[cfg(unix)]
        {
            let link = directory.join("link.yaml");
            std::os::unix::fs::symlink(&path, &link).unwrap();
            assert!(adapters(&link, &[Provider::OpenRouter], None).is_err());
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
}
