//! A read-only companion listener shares the host's scheduler and vault.
use super::*;
use axum::Extension;
use serde::Deserialize;
use std::net::{IpAddr, SocketAddr};

use crate::cli::SharingMode as Mode;

#[derive(serde::Serialize)]
struct NetworkAddress {
    mode: Mode,
    address: String,
    interface: String,
}

// ponytail: assigned CGNAT IPv4 hints at Tailscale; use its LocalAPI if other CGNAT VPNs need disambiguation.
fn network_mode(ip: IpAddr, broadcast: bool) -> Option<Mode> {
    match ip {
        IpAddr::V4(ip) if ip.octets()[0] == 100 && (64..=127).contains(&ip.octets()[1]) => {
            Some(Mode::Tailscale)
        }
        IpAddr::V4(ip) if broadcast && (ip.is_private() || ip.is_link_local()) => {
            Some(Mode::LocalNetwork)
        }
        _ => None,
    }
}
fn addresses() -> Result<Vec<NetworkAddress>, ApiError> {
    let interfaces = if_addrs::get_if_addrs()
        .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "network_discovery_failed"))?;
    let mut values: Vec<_> = interfaces
        .into_iter()
        .filter(|item| item.is_oper_up())
        .filter_map(|item| {
            let broadcast =
                matches!(&item.addr, if_addrs::IfAddr::V4(address) if address.broadcast.is_some());
            network_mode(item.ip(), broadcast).map(|mode| NetworkAddress {
                mode,
                address: item.ip().to_string(),
                interface: item.name,
            })
        })
        .collect();
    values.sort_by(|a, b| a.address.cmp(&b.address));
    values.dedup_by(|a, b| a.address == b.address);
    Ok(values)
}

#[derive(Default)]
pub(super) struct Sharing {
    endpoints: Vec<Endpoint>,
}

#[derive(Default)]
struct Endpoint {
    listener: Option<tokio::task::JoinHandle<()>>,
    tls_handle: Option<axum_server::Handle<SocketAddr>>,
    certificate: Option<String>,
    mode: Mode,
    address: Option<SocketAddr>,
    origin: Option<String>,
    active: Option<Arc<std::sync::atomic::AtomicBool>>,
    shutdown: Option<watch::Sender<bool>>,
}
impl Drop for Endpoint {
    fn drop(&mut self) {
        self.stop();
    }
}
impl Endpoint {
    fn view(&self) -> Value {
        json!({"schema_version":2,
               "enabled":self.listener.as_ref().is_some_and(|task| !task.is_finished()),
               "listen":self.address.map(|address| address.to_string()), "public_url":self.origin, "mode": self.mode, "certificate": self.certificate})
    }
    pub fn stop(&mut self) {
        if let Some(active) = self.active.take() {
            active.store(false, Ordering::SeqCst);
        }
        if let Some(handle) = self.tls_handle.take() {
            handle.graceful_shutdown(Some(std::time::Duration::from_secs(2)));
        }
        self.certificate = None;
        if let Some(shutdown) = self.shutdown.take() {
            shutdown.send_replace(true);
        }
        // Axum closes idle keep-alive connections and lets already-started reads finish.
        self.listener.take();
        self.address = None;
        self.origin = None;
    }
}
impl Sharing {
    fn view(&self, selected: Option<Mode>) -> Value {
        let endpoints: Vec<_> = self.endpoints.iter().map(Endpoint::view).collect();
        let mut view = self
            .endpoints
            .iter()
            .find(|endpoint| {
                selected.is_none_or(|mode| endpoint.mode == mode)
                    && endpoint
                        .listener
                        .as_ref()
                        .is_some_and(|task| !task.is_finished())
            })
            .map(Endpoint::view)
            .unwrap_or_else(|| Endpoint::default().view());
        view["endpoints"] = json!(endpoints);
        view
    }

    pub fn stop(&mut self) {
        self.endpoints.clear();
    }

    fn disable(&mut self, mode: Mode) {
        self.endpoints.retain(|endpoint| endpoint.mode != mode);
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Update {
    enabled: bool,
    mode: Option<Mode>,
    listen: Option<SocketAddr>,
    public_url: Option<String>,
}
fn local_owner(principal: &security::Principal) -> Result<(), ApiError> {
    if principal.owner && principal.host_user {
        Ok(())
    } else {
        Err(ApiError(StatusCode::FORBIDDEN, "host_interaction_required"))
    }
}
pub(super) async fn get(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
) -> Result<Json<Value>, ApiError> {
    local_owner(&principal)?;
    let mut view = state.sharing.lock().await.view(None);
    view["addresses"] = serde_json::to_value(addresses()?).expect("serializable addresses");
    Ok(Json(view))
}
pub(super) async fn update(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    ApiJson(input): ApiJson<Update>,
) -> Result<Json<Value>, ApiError> {
    local_owner(&principal)?;
    let mut sharing = state.sharing.lock().await;
    if !input.enabled {
        if let Some(mode) = input.mode {
            sharing.disable(mode);
        } else {
            sharing.stop();
        }
        return Ok(Json(sharing.view(None)));
    }
    if state.vault.is_none() || state.no_saved_accounts {
        return Err(ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            "account_storage_disabled",
        ));
    }
    let address = input
        .listen
        .filter(|address| address.port() != 0)
        .ok_or(ApiError(StatusCode::BAD_REQUEST, "invalid_share_address"))?;
    let mode = input.mode.unwrap_or_default();
    let origin = if mode == Mode::Proxy {
        if !address.ip().is_loopback() {
            return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_share_address"));
        }
        input
            .public_url
            .ok_or(ApiError(StatusCode::BAD_REQUEST, "invalid_public_url"))?
    } else {
        if !addresses()?.iter().any(|candidate| {
            candidate.address == address.ip().to_string() && candidate.mode == mode
        }) {
            return Err(ApiError(
                StatusCode::BAD_REQUEST,
                "network_address_unavailable",
            ));
        }
        format!("https://{address}")
    };
    sharing.enable(state.clone(), mode, address, origin).await?;
    Ok(Json(sharing.view(Some(mode))))
}

impl Sharing {
    async fn enable(
        &mut self,
        state: Arc<ApiState>,
        mode: Mode,
        address: SocketAddr,
        origin: String,
    ) -> Result<(), ApiError> {
        let active = Arc::new(std::sync::atomic::AtomicBool::new(true));
        let policy = security::Policy::companion(address, &origin, active.clone())
            .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_public_url"))?;
        if self.endpoints.iter().any(|sharing| {
            sharing.address == Some(address)
                && sharing.mode == mode
                && sharing.origin.as_deref() == Some(&origin)
                && sharing
                    .listener
                    .as_ref()
                    .is_some_and(|task| !task.is_finished())
        }) {
            return Ok(());
        }
        // Never tear down a working endpoint to attempt a bind on a different port.
        if self
            .endpoints
            .iter()
            .any(|sharing| sharing.address == Some(address))
        {
            return Err(ApiError(
                StatusCode::CONFLICT,
                "disable_sharing_before_changing_origin",
            ));
        }
        let listener = TcpListener::bind(address)
            .await
            .map_err(|_| ApiError(StatusCode::CONFLICT, "share_port_unavailable"))?;
        let identity = if mode != Mode::Proxy {
            Some(
                crate::accounts::companion::identity(state.vault.clone().expect("checked vault"))
                    .await
                    .map_err(|error| {
                        ApiError(
                            StatusCode::SERVICE_UNAVAILABLE,
                            management::account_code(&error),
                        )
                    })?,
            )
        } else {
            None
        };
        let tls = identity
            .as_ref()
            .map(|identity| identity.tls(address.ip()))
            .transpose()
            .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "sharing_tls_unavailable"))?;
        let mut sharing = Endpoint::default();
        let router = router(state.clone(), Arc::new(policy));
        sharing.active = Some(active);
        sharing.mode = mode;
        sharing.certificate = identity
            .as_ref()
            .map(|identity| identity.certificate.clone());
        sharing.listener = Some(if let Some(tls) = tls {
            let handle = axum_server::Handle::new();
            sharing.tls_handle = Some(handle.clone());
            let listener = listener.into_std().map_err(|_| {
                ApiError(StatusCode::SERVICE_UNAVAILABLE, "sharing_tls_unavailable")
            })?;
            let server = axum_server::from_tcp_rustls(listener, tls.clone())
                .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "sharing_tls_unavailable"))?
                .handle(handle);
            tokio::spawn(async move {
                let server = server.serve(router.into_make_service());
                tokio::pin!(server);
                // Renew the short-lived leaf while keeping the QR-trusted CA stable.
                let period = std::time::Duration::from_secs(30 * 24 * 60 * 60);
                let mut renewal =
                    tokio::time::interval_at(tokio::time::Instant::now() + period, period);
                loop {
                    tokio::select! {
                        result = &mut server => {
                            if result.is_err() { tracing::warn!("companion_listener_stopped"); }
                            break;
                        }
                        _ = renewal.tick() => {
                            match identity.as_ref().expect("TLS identity").tls(address.ip()) {
                                Ok(config) => tls.reload_from_config(config.get_inner()),
                                Err(_) => tracing::warn!("companion_certificate_renewal_failed"),
                            }
                        }
                    }
                }
            })
        } else {
            let (shutdown, mut stopped) = watch::channel(false);
            sharing.shutdown = Some(shutdown);
            tokio::spawn(async move {
                if axum::serve(listener, router)
                    .with_graceful_shutdown(async move {
                        let _ = stopped.wait_for(|value| *value).await;
                    })
                    .await
                    .is_err()
                {
                    tracing::warn!("companion_listener_stopped");
                }
            })
        });
        sharing.address = Some(address);
        sharing.origin = Some(origin);
        self.disable(mode);
        self.endpoints.push(sharing);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    #[ignore = "explicit Swift/iOS TLS smoke with synthetic credentials"]
    async fn serve_apple_tls_smoke() {
        let directory = std::path::PathBuf::from(
            std::env::var("QUOTIO_TLS_SMOKE_DIR").expect("isolated output directory"),
        );
        std::fs::create_dir_all(&directory).unwrap();
        let (mut state, fixture_directory, _) = crate::server::tests::fixture().await;
        Arc::get_mut(&mut state).unwrap().no_saved_accounts = false;
        let vault = state.vault.clone().unwrap();
        let identity = crate::accounts::companion::identity(vault.clone())
            .await
            .unwrap();
        let grant = crate::accounts::clients::create(
            vault,
            crate::accounts::clients::Create {
                label: "Synthetic Apple test".into(),
                scope: crate::accounts::clients::Scope::Read,
                expires_in_seconds: 3600,
            },
            state.context.clock.now(),
        )
        .await
        .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let origin = format!("https://{address}");
        let active = Arc::new(std::sync::atomic::AtomicBool::new(true));
        let app = router(
            state,
            Arc::new(security::Policy::companion(address, &origin, active).unwrap()),
        );
        let handle = axum_server::Handle::new();
        let server = tokio::spawn(
            axum_server::from_tcp_rustls(
                listener.into_std().unwrap(),
                identity.tls(address.ip()).unwrap(),
            )
            .unwrap()
            .handle(handle.clone())
            .serve(app.into_make_service()),
        );
        let file = directory.join("pairing.json");
        std::fs::write(
            &file,
            serde_json::to_vec(
                &json!({"origin":origin,"token":grant.token,"certificate":identity.certificate}),
            )
            .unwrap(),
        )
        .unwrap();
        for _ in 0..600 {
            if directory.join("stop").exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }
        handle.shutdown();
        server.await.unwrap().unwrap();
        std::fs::remove_file(file).unwrap();
        std::fs::remove_dir_all(fixture_directory).unwrap();
    }

    #[tokio::test]
    async fn simultaneous_direct_endpoints_keep_independent_lifecycles_and_device_access() {
        use base64::Engine;
        let (mut state, directory, _) = crate::server::tests::fixture().await;
        Arc::get_mut(&mut state).unwrap().no_saved_accounts = false;
        let vault = state.vault.clone().unwrap();
        let mut grants = Vec::new();
        for label in ["LAN phone", "Tailscale phone"] {
            grants.push(
                crate::accounts::clients::create(
                    vault.clone(),
                    crate::accounts::clients::Create {
                        label: label.into(),
                        scope: crate::accounts::clients::Scope::Read,
                        expires_in_seconds: 60,
                    },
                    state.context.clock.now(),
                )
                .await
                .unwrap(),
            );
        }
        let mut origins = Vec::new();
        for mode in [Mode::LocalNetwork, Mode::Tailscale] {
            let candidate = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = candidate.local_addr().unwrap();
            drop(candidate);
            let origin = format!("https://{address}");
            state
                .sharing
                .lock()
                .await
                .enable(state.clone(), mode, address, origin.clone())
                .await
                .unwrap_or_else(|_| panic!("Could not enable sharing endpoint"));
            origins.push(origin);
        }
        let view = state.sharing.lock().await.view(None);
        assert_eq!(view["endpoints"].as_array().unwrap().len(), 2);
        assert_eq!(
            state.sharing.lock().await.view(Some(Mode::Tailscale))["public_url"],
            origins[1]
        );
        assert_eq!(
            view["endpoints"][0]["certificate"],
            view["endpoints"][1]["certificate"]
        );
        let cert = base64::engine::general_purpose::STANDARD
            .decode(view["endpoints"][0]["certificate"].as_str().unwrap())
            .unwrap();
        let client = reqwest::Client::builder()
            .no_proxy()
            .tls_built_in_root_certs(false)
            .add_root_certificate(reqwest::Certificate::from_der(&cert).unwrap())
            .build()
            .unwrap();
        for (origin, grant) in origins.iter().zip(&grants) {
            let response = client
                .get(format!("{origin}/v2/status"))
                .bearer_auth(&grant.token)
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), 200);
            let status: Value = response.json().await.unwrap();
            assert_eq!(status["access_mode"], "read_only");
            assert_eq!(status["client_id"], grant.client.id);
            for (path, expected) in [("v2/sharing", 403), ("v2/status", 401)] {
                let token = if expected == 401 {
                    "synthetic-owner-secret-123456789012345"
                } else {
                    &grant.token
                };
                assert_eq!(
                    client
                        .get(format!("{origin}/{path}"))
                        .bearer_auth(token)
                        .send()
                        .await
                        .unwrap()
                        .status(),
                    expected
                );
            }
        }
        let occupied = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let occupied_address = occupied.local_addr().unwrap();
        let failed = state
            .sharing
            .lock()
            .await
            .enable(
                state.clone(),
                Mode::LocalNetwork,
                occupied_address,
                format!("https://{occupied_address}"),
            )
            .await;
        assert!(matches!(
            failed,
            Err(ApiError(StatusCode::CONFLICT, "share_port_unavailable"))
        ));
        assert_eq!(
            state.sharing.lock().await.view(None)["endpoints"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        let stopped = update(
            State(state.clone()),
            security::owner(),
            ApiJson(Update {
                enabled: false,
                mode: Some(Mode::Tailscale),
                listen: None,
                public_url: None,
            }),
        )
        .await
        .unwrap_or_else(|_| panic!("Could not disable sharing"))
        .0;
        assert_eq!(stopped["endpoints"].as_array().unwrap().len(), 1);
        assert_eq!(stopped["endpoints"][0]["mode"], "local_network");
        assert_eq!(
            client
                .get(format!("{}/v2/status", origins[0]))
                .bearer_auth(&grants[0].token)
                .send()
                .await
                .unwrap()
                .status(),
            200
        );
        if let Ok(response) = client
            .get(format!("{}/v2/status", origins[1]))
            .bearer_auth(&grants[1].token)
            .send()
            .await
        {
            assert_eq!(response.status(), 503);
        }
        crate::accounts::clients::revoke(vault, grants[0].client.id.clone())
            .await
            .unwrap();
        assert_eq!(
            client
                .get(format!("{}/v2/status", origins[0]))
                .bearer_auth(&grants[0].token)
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
        assert_eq!(
            client
                .get(format!("{}/v2/status", origins[0]))
                .bearer_auth(&grants[1].token)
                .send()
                .await
                .unwrap()
                .status(),
            200
        );
        let stopped = update(
            State(state.clone()),
            security::owner(),
            ApiJson(Update {
                enabled: false,
                mode: None,
                listen: None,
                public_url: None,
            }),
        )
        .await
        .unwrap_or_else(|_| panic!("Could not disable sharing"))
        .0;
        assert_eq!(stopped["enabled"], false);
        assert!(stopped["endpoints"].as_array().unwrap().is_empty());
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn discovery_never_offers_public_loopback_or_wildcard_addresses() {
        for value in ["0.0.0.0", "127.0.0.1", "8.8.8.8", "::1", "::"] {
            assert!(network_mode(value.parse().unwrap(), true).is_none());
        }
        assert!(matches!(
            network_mode("192.168.1.9".parse().unwrap(), true),
            Some(Mode::LocalNetwork)
        ));
        assert!(matches!(
            network_mode("100.64.0.1".parse().unwrap(), false),
            Some(Mode::Tailscale)
        ));
        assert!(network_mode("100.128.0.1".parse().unwrap(), false).is_none());
        assert!(network_mode("172.16.0.2".parse().unwrap(), false).is_none());
    }

    #[tokio::test]
    async fn tls_requires_paired_ca_preserves_identity_and_rejects_owner_tokens() {
        use base64::Engine;
        let (mut state, directory, _) = crate::server::tests::fixture().await;
        Arc::get_mut(&mut state).unwrap().no_saved_accounts = false;
        let vault = state.vault.clone().unwrap();
        let identity = crate::accounts::companion::identity(vault.clone())
            .await
            .unwrap();
        assert_eq!(
            identity.certificate,
            crate::accounts::companion::identity(vault.clone())
                .await
                .unwrap()
                .certificate
        );
        assert_eq!(vault.begin().unwrap().document.version, 19);
        let grant = crate::accounts::clients::create(
            vault,
            crate::accounts::clients::Create {
                label: "TLS phone".into(),
                scope: crate::accounts::clients::Scope::Read,
                expires_in_seconds: 60,
            },
            state.context.clock.now(),
        )
        .await
        .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let origin = format!("https://{address}");
        let active = Arc::new(std::sync::atomic::AtomicBool::new(true));
        let app = router(
            state.clone(),
            Arc::new(security::Policy::companion(address, &origin, active).unwrap()),
        );
        let tls = identity.tls(address.ip()).unwrap();
        let handle = axum_server::Handle::new();
        let server = tokio::spawn(
            axum_server::from_tcp_rustls(listener.into_std().unwrap(), tls)
                .unwrap()
                .handle(handle.clone())
                .serve(app.into_make_service()),
        );
        let cert = base64::engine::general_purpose::STANDARD
            .decode(&identity.certificate)
            .unwrap();
        let client = reqwest::Client::builder()
            .tls_built_in_root_certs(false)
            .add_root_certificate(reqwest::Certificate::from_der(&cert).unwrap())
            .build()
            .unwrap();
        let url = format!("{origin}/v2/status");
        assert!(
            reqwest::Client::new()
                .get(&url)
                .bearer_auth(&grant.token)
                .send()
                .await
                .is_err()
        );
        let response = client
            .get(&url)
            .bearer_auth(&grant.token)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        let status: Value = response.json().await.unwrap();
        assert_eq!(status["access_mode"], "read_only");
        assert_eq!(
            client
                .get(&url)
                .bearer_auth("synthetic-owner-secret-123456789012345")
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
        assert_eq!(
            client
                .get(format!("{origin}/v2/sharing"))
                .bearer_auth(&grant.token)
                .send()
                .await
                .unwrap()
                .status(),
            403
        );
        assert_eq!(
            client
                .post(format!("{origin}/v2/refresh"))
                .bearer_auth(&grant.token)
                .json(&json!({}))
                .send()
                .await
                .unwrap()
                .status(),
            405
        );
        handle.shutdown();
        server.await.unwrap().unwrap();
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn companion_listener_preserves_local_owner_and_rejects_remote_authority() {
        let (mut state, directory, _) = crate::server::tests::fixture().await;
        Arc::get_mut(&mut state).unwrap().no_saved_accounts = false;
        let vault = state.vault.clone().unwrap();
        let grant = crate::accounts::clients::create(
            vault.clone(),
            crate::accounts::clients::Create {
                label: "Synthetic phone".into(),
                scope: crate::accounts::clients::Scope::Read,
                expires_in_seconds: 60,
            },
            state.context.clock.now(),
        )
        .await
        .unwrap();
        let local = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let local_address = local.local_addr().unwrap();
        let owner = "synthetic-local-owner-secret-123456";
        let app = router(
            state.clone(),
            Arc::new(
                security::Policy::new(local_address, true, None, &[], Some(owner.into())).unwrap(),
            ),
        );
        let server = tokio::spawn(async move { axum::serve(local, app).await.unwrap() });
        let candidate = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = candidate.local_addr().unwrap();
        drop(candidate);
        let client = reqwest::Client::new();
        let base = format!("http://{local_address}");
        let invalid = client
            .put(format!("{base}/v2/sharing"))
            .bearer_auth(owner)
            .json(&json!({"enabled":true,"mode":"local_network","listen":"0.0.0.0:6768"}))
            .send()
            .await
            .unwrap();
        assert_eq!(invalid.status(), 400);
        let response = client.put(format!("{base}/v2/sharing")).bearer_auth(owner)
            .json(&json!({"enabled":true,"listen":address.to_string(),"public_url":"https://companion.example.test"}))
            .send().await.unwrap();
        assert_eq!(response.status(), 200);
        let remote = format!("http://{address}");
        let status: Value = client
            .get(format!("{remote}/v2/status"))
            .bearer_auth(&grant.token)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(status["access_mode"], "read_only");
        assert_eq!(status["client_id"], grant.client.id);
        assert_eq!(
            client
                .get(format!("{remote}/v2/status"))
                .bearer_auth(owner)
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
        assert_eq!(
            client
                .post(format!("{remote}/v2/refresh"))
                .bearer_auth(&grant.token)
                .json(&json!({}))
                .send()
                .await
                .unwrap()
                .status(),
            405
        );
        assert_eq!(
            client
                .get(format!("{remote}/v2/clients"))
                .bearer_auth(&grant.token)
                .send()
                .await
                .unwrap()
                .status(),
            403
        );
        let local_status: Value = client
            .get(format!("{base}/v2/status"))
            .bearer_auth(owner)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(local_status["access_mode"], "manage");
        let second = crate::accounts::clients::create(
            vault.clone(),
            crate::accounts::clients::Create {
                label: "Second phone".into(),
                scope: crate::accounts::clients::Scope::Read,
                expires_in_seconds: 60,
            },
            state.context.clock.now(),
        )
        .await
        .unwrap();
        assert_eq!(
            client
                .get(format!("{remote}/v2/status"))
                .bearer_auth(&second.token)
                .send()
                .await
                .unwrap()
                .status(),
            200
        );
        crate::accounts::clients::revoke(vault, grant.client.id)
            .await
            .unwrap();
        assert_eq!(
            client
                .get(format!("{remote}/v2/status"))
                .bearer_auth(&grant.token)
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
        assert_eq!(
            client
                .put(format!("{base}/v2/sharing"))
                .bearer_auth(owner)
                .json(&json!({"enabled":false}))
                .send()
                .await
                .unwrap()
                .status(),
            200
        );
        if let Ok(response) = client
            .get(format!("{remote}/v2/status"))
            .bearer_auth(&second.token)
            .send()
            .await
        {
            assert_eq!(response.status(), 503);
        }
        server.abort();
        std::fs::remove_dir_all(directory).unwrap();
    }
}
