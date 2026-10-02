use crate::{
    cli::Provider,
    config::Config,
    contract::{Availability, Snapshot},
    fetch::{Cancellation, CollectRequest, Collector},
    providers::{EnvironmentCredentials, ProviderContext, SystemClock},
};
use std::{path::PathBuf, sync::Arc, time::Duration};

#[derive(Clone)]
pub struct Request {
    pub force: bool,
    pub providers: Vec<Provider>,
    pub timeout: u64,
    pub config: Option<PathBuf>,
    pub cli_proxy_auth_dir: Option<PathBuf>,
    pub cli_proxy_config: Option<PathBuf>,
    pub no_saved_accounts: bool,
    pub account: Option<String>,
}

pub struct Collected {
    pub snapshot: Snapshot,
    pub diagnostics: String,
    pub exit_code: u8,
}

pub struct Error {
    pub message: String,
    pub exit_code: u8,
}

pub async fn collect(request: Request) -> Result<Collected, Error> {
    let config = Config::load(request.config.as_deref()).map_err(|error| Error {
        message: error.to_string(),
        exit_code: 2,
    })?;
    config.providers().map_err(|error| Error {
        message: error.to_string(),
        exit_code: 2,
    })?;
    let disabled = config.disabled_providers().map_err(|error| Error {
        message: error.to_string(),
        exit_code: 2,
    })?;
    let automatic = request.providers.is_empty();
    let mut selected = Vec::new();
    for provider in request.providers {
        if !selected.contains(&provider) {
            selected.push(provider);
        }
    }
    if request.account.is_some() && selected.len() != 1 {
        return Err(Error {
            message: "--account requires exactly one --provider.".into(),
            exit_code: 2,
        });
    }
    use clap::ValueEnum;
    let proxy_providers = if automatic {
        Provider::value_variants()
            .iter()
            .copied()
            .filter(|provider| *provider != Provider::Mock && !disabled.contains(provider))
            .collect::<Vec<_>>()
    } else {
        selected.clone()
    };
    let proxy_auth_directory = request
        .cli_proxy_auth_dir
        .or_else(crate::accounts::proxy::default_auth_directory);
    let borrowed = crate::accounts::proxy::sources(
        proxy_auth_directory.as_deref(),
        request.cli_proxy_config.as_deref(),
        &proxy_providers,
        request.account.as_deref(),
        &config.disabled_proxy_auth_files,
    )
    .map_err(|error| Error {
        message: error.to_string(),
        exit_code: 2,
    })?;
    let providers = tokio::select! {
        providers = async {
            if request.account.is_some() && !borrowed.is_empty() {
                return Ok(borrowed);
            }
            let mut providers = if let Some(id) = request.account.as_deref().filter(|id| *id != "local") {
                if request.no_saved_accounts {
                    return Err(crate::accounts::AccountError::NotFound);
                }
                let provider = selected
                    .first()
                    .copied()
                    .ok_or(crate::accounts::AccountError::Unsupported)?;
                crate::accounts::service::resolved_adapters(crate::accounts::vault::Vault::for_usage()?, provider, id).await
            } else if automatic {
                crate::accounts::service::detected_adapters(
                    disabled,
                    !request.no_saved_accounts,
                    Duration::from_secs(request.timeout),
                ).await
            } else {
                crate::accounts::service::adapters(
                    selected,
                    !request.no_saved_accounts,
                    Duration::from_secs(request.timeout),
                    request.account.as_deref(),
                ).await
            }?;
            if request.account.is_none() {
                providers.extend(borrowed);
            }
            Ok(providers)
        } => providers.map_err(|error| Error { message: error.to_string(), exit_code: 2 })?,
        _ = tokio::signal::ctrl_c() => return Err(Error { message: "Account discovery cancelled.".into(), exit_code: 3 }),
    };
    let mut diagnostics = String::new();
    if providers.is_empty() {
        diagnostics.push_str(
            "No providers detected. Sign in to a supported provider or use --provider explicitly.\n",
        );
    }
    tracing::debug!(count = providers.len(), "collecting provider usage");
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| Error {
            message: "Could not initialize HTTP client.".into(),
            exit_code: 3,
        })?;
    let collector = Collector {
        context: ProviderContext {
            http,
            clock: Arc::new(SystemClock),
            credentials: Arc::new(EnvironmentCredentials),
        },
    };
    let cancellation = Cancellation::default();
    let scope: std::collections::HashSet<String> =
        providers.iter().map(|provider| provider.id().0).collect();
    let source_scope: std::collections::HashSet<String> = providers
        .iter()
        .flat_map(|provider| {
            provider
                .account_ref()
                .map(|reference| {
                    [
                        crate::contract::snapshot::external_id(&provider.id().0, Some(&reference)),
                        reference.id,
                    ]
                })
                .into_iter()
                .flatten()
        })
        .collect();
    let saved = !request.no_saved_accounts
        && providers.iter().any(|provider| {
            provider.account_ref().is_some_and(|reference| {
                reference.id != "local"
                    && reference.origin != Some(crate::domain::AccountOrigin::BorrowedProxy)
            })
        });
    let cache = crate::cache::UsageCache::platform(Duration::from_secs(config.cache_ttl_seconds));
    let collection = cache.collect(
        &collector,
        CollectRequest {
            providers,
            timeout: Duration::from_secs(request.timeout),
            cancellation: cancellation.clone(),
        },
        request.force,
    );
    tokio::pin!(collection);
    let report = tokio::select! {
        report = &mut collection => report,
        signal = tokio::signal::ctrl_c() => {
            if signal.is_err() {
                diagnostics.push_str("Could not listen for Ctrl-C.\n");
            }
            cancellation.cancel();
            collection.await
        }
    };
    let exit_code = report.exit_code();
    let now = collector.context.clock.now();
    let ttl = time::Duration::seconds(config.cache_ttl_seconds.min(i64::MAX as u64) as i64);
    let mut snapshot = if saved {
        let vault = crate::accounts::vault::Vault::for_usage().map_err(|error| Error {
            message: error.to_string(),
            exit_code: 3,
        })?;
        crate::accounts::api::resolved_snapshot(vault, report, now, ttl)
            .await
            .map_err(|error| Error {
                message: error.to_string(),
                exit_code: 3,
            })?
    } else {
        crate::accounts::resolved::Registry::new(&[])
            .and_then(|registry| registry.account_list(&[]))
            .and_then(|mut accounts| {
                accounts.host.capabilities.insert(
                    "account_write_v2".into(),
                    Availability {
                        available: false,
                        reason: Some("no_saved_accounts".into()),
                    },
                );
                crate::contract::snapshot::project(accounts, &report, now, ttl)
                    .map_err(|_| crate::accounts::AccountError::Snapshot)
            })
            .map_err(|error| Error {
                message: error.to_string(),
                exit_code: 3,
            })?
    };
    snapshot.accounts.retain(|account| {
        scope.contains(&account.provider_id)
            && (request.account.is_none()
                || request.account.as_deref() == Some("local")
                || account
                    .sources
                    .iter()
                    .any(|source| source_scope.contains(&source.id)))
    });
    snapshot.usage.retain(|usage| {
        snapshot
            .accounts
            .iter()
            .any(|account| account.id == usage.account_id)
    });
    diagnostics.push_str(&crate::output::text::snapshot_failures(&snapshot));
    snapshot.account_redirects.retain(|_, target| {
        snapshot
            .accounts
            .iter()
            .any(|account| account.id == *target)
    });
    Ok(Collected {
        snapshot,
        diagnostics,
        exit_code,
    })
}
