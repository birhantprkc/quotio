# Provider contract coverage

This table is derived from `quotio providers --format json`. The contract test
checks every row against the runtime registry. `—` means the capability is absent;
platform declarations are implementation metadata, not runtime test results.

Every provider uses Rust's shared naming, account/source actions, metric states and
error projection. Verified cross-source grouping is currently supplied by Devin
Desktop, Copilot and Factory API-key responses; other sources retain distinct IDs
when identity evidence is unavailable. User labels always remain authoritative.
Missing metrics remain missing, and failures never imply zero or full quota.

Contract coverage is offline: registry/schema tests cover all entries, shared
snapshot fixtures cover plan-only and grouped-source results, and adapter tests
cover provider payload parsing. This is not a claim of live-account acceptance for
all providers. Windows/Linux runtime checks are deferred.

<!-- registry-table -->
| Provider | Authentication | Sources (ownership) | Account storage OS |
| --- | --- | --- | --- |
| mock | — | — | — |
| codex | oauth, native | codex_native (borrowed_native), cli_proxy_auth_file (borrowed_proxy) | macos, linux |
| amp | api_key, native | amp_native (borrowed_native) | macos, linux |
| antigravity | native, owned_token | antigravity_native (borrowed_native), cli_proxy_auth_file (borrowed_proxy) | macos, linux |
| synthetic | api_key | cli_proxy_auth_file (borrowed_proxy) | macos, linux |
| openrouter | api_key | cli_proxy_auth_file (borrowed_proxy) | macos, linux |
| zai | api_key | quotio_custom_provider (borrowed_proxy), cli_proxy_auth_file (borrowed_proxy) | macos, linux |
| minimax | api_key | cli_proxy_auth_file (borrowed_proxy) | macos, linux |
| factory | api_key, owned_token, native | factory_native (borrowed_native) | macos, linux |
| aiand | api_key | — | macos, linux |
| alibabacodingplan | api_key | — | macos, linux |
| azureopenai | native | — | — |
| chutes | api_key | — | macos, linux |
| claude | oauth, native | claude_native (borrowed_native), cli_proxy_auth_file (borrowed_proxy) | macos, linux |
| clawrouter | api_key | — | macos, linux |
| clinepass | api_key | quotio_custom_provider (borrowed_proxy) | macos, linux |
| codebuff | api_key | — | macos, linux |
| copilot | oauth, native | copilot_native (borrowed_native), cli_proxy_auth_file (borrowed_proxy) | macos, linux |
| crof | api_key | — | macos, linux |
| cursor | native | cursor_native (borrowed_native) | macos, linux |
| deepgram | api_key | — | macos, linux |
| deepinfra | api_key | — | macos, linux |
| deepseek | api_key | cli_proxy_auth_file (borrowed_proxy) | macos, linux |
| devin | api_key | — | macos, linux |
| devin-desktop | api_key | devin_desktop_native (borrowed_native) | macos, linux |
| doubao | api_key | — | macos, linux |
| elevenlabs | api_key | — | macos, linux |
| fireworks | api_key | — | macos, linux |
| gemini | native | cli_proxy_auth_file (borrowed_proxy) | — |
| grok | native, owned_token | grok_native (borrowed_native) | macos, linux |
| groq | api_key | — | macos, linux |
| ibmbob | api_key | — | macos, linux |
| kilo | api_key | — | macos, linux |
| kimi | api_key | — | macos, linux |
| kiro | native, owned_token | kiro_native (borrowed_native), cli_proxy_auth_file (borrowed_proxy) | macos, linux |
| litellm | api_key | — | macos, linux |
| llmproxy | api_key | — | macos, linux |
| moonshot | api_key | cli_proxy_auth_file (borrowed_proxy) | macos, linux |
| neuralwatt | api_key | — | macos, linux |
| openai | api_key | — | macos, linux |
| opencodego | api_key | — | macos, linux |
| poe | api_key | cli_proxy_auth_file (borrowed_proxy) | macos, linux |
| sub2api | api_key | — | macos, linux |
| venice | api_key | cli_proxy_auth_file (borrowed_proxy) | macos, linux |
| vertexai | native | cli_proxy_auth_file (borrowed_proxy) | — |
| warp | api_key | — | macos, linux |
| xai | api_key | — | macos, linux |
| zenmux | api_key | — | macos, linux |
