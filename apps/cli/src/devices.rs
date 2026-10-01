//! Owner-side device management. Credentials are read from the environment, never argv.
use crate::cli::{DeviceCommand, DevicesArgs, SharingArgs, SharingCommand};
use serde_json::{Value, json};
use std::time::Duration;

fn owner_client(api: &str) -> Result<(reqwest::Url, reqwest::Client, String), &'static str> {
    let base = reqwest::Url::parse(api).map_err(|_| "invalid_local_api")?;
    if base.scheme() != "http"
        || !matches!(base.host_str(), Some("127.0.0.1" | "[::1]"))
        || !base.username().is_empty()
        || base.password().is_some()
        || base.query().is_some()
        || base.fragment().is_some()
        || base.path() != "/"
    {
        return Err("invalid_local_api");
    }
    let token = std::env::var("QUOTIO_SERVER_TOKEN").map_err(|_| "server_token_required")?;
    if !(32..=4096).contains(&token.len()) || !token.bytes().all(|b| b.is_ascii_graphic()) {
        return Err("invalid_server_token");
    }
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|_| "client_unavailable")?;
    Ok((base, client, token))
}

pub async fn run_sharing(args: SharingArgs) -> Result<Value, &'static str> {
    let (base, client, token) = owner_client(&args.api)?;
    let mut request = client.get(base.join("v2/sharing").map_err(|_| "invalid_local_api")?);
    let body = match args.command {
        SharingCommand::Status => None,
        SharingCommand::Enable {
            mode,
            address,
            port,
            public_url,
        } => Some(json!({
            "enabled":true, "mode":mode,
            "listen":std::net::SocketAddr::new(address.unwrap_or(std::net::Ipv4Addr::LOCALHOST.into()), port).to_string(),
            "public_url":public_url,
        })),
        SharingCommand::Disable { mode } => Some(json!({"enabled":false,"mode":mode})),
    };
    if let Some(body) = body {
        request = client
            .put(base.join("v2/sharing").map_err(|_| "invalid_local_api")?)
            .json(&body);
    }
    let response = request
        .bearer_auth(token)
        .send()
        .await
        .map_err(|_| "host_unavailable")?;
    if !response.status().is_success() {
        return Err("sharing_request_rejected");
    }
    response.json().await.map_err(|_| "invalid_host_response")
}

pub async fn run(args: DevicesArgs) -> Result<Value, &'static str> {
    let (base, client, token) = owner_client(&args.api)?;
    let (method, path, body, origin) = match args.command {
        DeviceCommand::Add {
            label,
            public_url,
            expires_in_seconds,
        } => {
            let origin = reqwest::Url::parse(&public_url).map_err(|_| "invalid_public_url")?;
            if origin.scheme() != "https"
                || origin.host_str().is_none()
                || !origin.username().is_empty()
                || origin.password().is_some()
                || origin.path() != "/"
                || origin.query().is_some()
                || origin.fragment().is_some()
            {
                return Err("invalid_public_url");
            }
            (
                reqwest::Method::POST,
                "v2/clients".to_owned(),
                Some(json!({"label":label,"scope":"read","expires_in_seconds":expires_in_seconds})),
                Some(origin.origin().ascii_serialization()),
            )
        }
        DeviceCommand::List => (reqwest::Method::GET, "v2/clients".into(), None, None),
        DeviceCommand::Revoke { id } => {
            if !crate::contract::valid_id(&id) {
                return Err("invalid_client_id");
            }
            (
                reqwest::Method::DELETE,
                format!("v2/clients/{id}"),
                None,
                None,
            )
        }
    };
    // Read trust before issuing: a failed metadata read must not lose a newly created grant.
    let mut certificate = None;
    if let Some(origin) = &origin {
        let response = client
            .get(base.join("v2/sharing").map_err(|_| "invalid_local_api")?)
            .bearer_auth(&token)
            .send()
            .await
            .map_err(|_| "host_unavailable")?;
        if response.status().is_success() {
            let sharing: Value = response.json().await.map_err(|_| "invalid_host_response")?;
            let endpoint = if let Some(endpoints) = sharing["endpoints"].as_array() {
                endpoints.iter().find(|endpoint| {
                    endpoint["enabled"] == true
                        && endpoint["public_url"].as_str() == Some(origin.as_str())
                })
            } else {
                (sharing["enabled"] == true
                    && sharing["public_url"].as_str() == Some(origin.as_str()))
                .then_some(&sharing)
            };
            if let Some(endpoint) = endpoint {
                certificate = endpoint["certificate"].as_str().map(str::to_owned);
            }
        } else if !matches!(response.status().as_u16(), 403 | 404) {
            return Err("device_request_rejected");
        }
    }
    let mut request = client
        .request(method, base.join(&path).map_err(|_| "invalid_local_api")?)
        .bearer_auth(token);
    if let Some(body) = body {
        request = request.json(&body);
    }
    let response = request.send().await.map_err(|_| "host_unavailable")?;
    if !response.status().is_success() {
        return Err("device_request_rejected");
    }
    if response.status() == reqwest::StatusCode::NO_CONTENT {
        return Ok(json!({"revoked":true}));
    }
    let value: Value = response.json().await.map_err(|_| "invalid_host_response")?;
    if let Some(origin) = origin {
        // Issuance is not retried. A lost response must be revoked by ID before reissuing.
        if value["schema_version"] != 2
            || value["client"]["scope"] != "read"
            || !value["token"].is_string()
            || !value["host_id"].is_string()
        {
            return Err("invalid_host_response");
        }
        let mut pairing = json!({"pairing_version":2,
            "host_name":reqwest::Url::parse(&origin).map_err(|_| "invalid_public_url")?.host_str(),
            "origin":origin,"host_id":value["host_id"],"client_id":value["client"]["id"],
            "expires_at":value["client"]["expires_at"],"token":value["token"]});
        if let Some(certificate) = certificate {
            pairing["certificate"] = certificate.into();
        }
        return Ok(pairing);
    }
    Ok(value)
}
