# Quotio for iPhone

Quotio displays host-owned quota and analytics over HTTPS on a LAN or private VPN.
It includes native Usage and Settings tabs plus six WidgetKit families.
Provider credentials stay on the computer. The phone receives a revocable read-only
credential, stored in Keychain. No Quotio cloud service is required.

## Build and test

Open `Quotio.xcodeproj`, select `QuotioIOS` and an iOS 26+ iPhone Simulator.
The checked-in project builds without XcodeGen. Run these commands from the
repository root; regenerate the project after adding files:

```sh
./scripts/dev ios-sim [SIMULATOR_UDID]
./scripts/dev ios-device [DEVICE_ID]
./scripts/dev test ios [SIMULATOR_UDID]
xcodegen generate --spec apps/ios/project.yml
swift test --package-path apps/ios
swift test --package-path Packages/QuotioHostClient
xcodebuild -project apps/ios/Quotio.xcodeproj -scheme QuotioIOS -showdestinations
```

Run `xcodebuild test` with a destination listed by the last command. The scheme
includes the widget extension and UI tests. Explore Demo works offline with clearly
labelled synthetic data; it does not persist demo accounts or credentials.

For physical devices, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` and set your signing team there. The local file is ignored
by Git; never put the team ID in `project.yml` or the generated project. Debug
includes it automatically, matching the macOS setup. Release intentionally does
not include it; explicitly pass it when creating a local signed archive:

```sh
xcodebuild -project apps/ios/Quotio.xcodeproj -scheme QuotioIOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -xcconfig apps/ios/Config/Local.xcconfig -allowProvisioningUpdates \
  -archivePath /tmp/QuotioIOS-signed.xcarchive archive
```

Use the same team for app and widget, with App Group
`group.app.bytrong.quotio.ios` and Keychain group
`$(AppIdentifierPrefix)app.bytrong.quotio.ios.hosts`. Automatic signing needs access
to that team's certificates and profiles. Simulator builds retain ad-hoc signing.
Do not commit certificates, provisioning profiles, archives or signing secrets.

## Connect the macOS app

Choose **Pair iPhone…** directly in the Quotio menu; the main window stays closed.
Choose **Local network** for the same Wi-Fi/Ethernet network, or **Tailscale IP**
with Tailscale connected on both devices. Quotio discovers active IPv4 addresses;
if several are available, select the one reachable by your iPhone. No domain or
reverse proxy is needed. Name the iPhone and create its pairing code. Quotio enables
sharing for the selected connection as part of that action when needed. LAN and
Tailscale can stay enabled together. Choose LAN when pairing one iPhone and
Tailscale when pairing another; each code contains that connection's address.

Scan the QR inside the updated Quotio iPhone app, or choose **Copy pairing code**
on Mac and **Paste** on iPhone. Confirm the address before connecting. Copy the whole
code: direct connections need its certificate as well as its device token.
The host's private key stays in its credential vault. The phone and widgets trust
only the paired CA for this connection, with normal hostname/expiry/signature checks.
No certificate profile or device-wide trust installation is required.

**Advanced** in Settings keeps the sharing port and optional custom HTTPS reverse
proxy. Turn the selected connection off before changing its settings; other connections stay on. If the host address changes,
pair again from the new address; existing saved profiles do not discover address
changes automatically.

Use **Settings… → iPhone sharing** to review and revoke authorized devices. Closing
the pairing view retains its current code in memory; reopening does not issue a new
credential. Done clears the displayed code without revoking the device. Codes also
clear on expiry, revocation or an endpoint change. Existing grants cannot be shown
again once their in-memory code is cleared.

Keep this Mac awake and Quotio running. Allow the sharing port through your firewall.
Listening does not prove iPhone reachability. Automatic discovery currently uses
private/link-local IPv4 for LAN and assigned `100.64.0.0/10` addresses for Tailscale;
other VPNs using that range may appear. IPv6-only networks need the custom HTTPS path.

## Connect a CLI host

Start a current host with saved-account storage, management enabled and an owner
token in `QUOTIO_SERVER_TOKEN`. Keep its owner API on loopback:

```sh
quotio serve --manage --listen 127.0.0.1:6767
```

Use the local-owner [sharing API](../cli/docs/local-http-api.md#iphone-companion) to
list network addresses, or use the CLI to enable both connections:

```sh
quotio sharing enable --mode local-network --address 192.168.1.10
quotio sharing enable --mode tailscale --address 100.64.0.2
quotio sharing status
```

Issue a device code using the chosen endpoint’s `public_url`:

```sh
quotio devices add --label iPhone --public-url https://192.168.1.10:6768
quotio devices list
quotio devices revoke CLIENT_ID
```

These commands read the owner token from the environment. `--api` selects another
loopback owner port. The add result includes the companion CA when its origin matches
the active direct listener. Paste the sensitive JSON into Quotio iPhone, or encode it
as a QR locally. Never share the owner token. Lost output: list/revoke the device
and issue again. Version 2 proxy codes without a companion certificate open the
Advanced form for explicit review before connecting. No public tunnel or automatic
VPN installation is included.

The companion listener shares the host process, scheduler and vault, and accepts
only delegated reads. The local owner endpoint retains OAuth and OS-approval authority.
Disabling a connection blocks its new requests, including old keep-alive connections; already
started reads may finish. Creating the direct TLS identity upgrades the vault to
format 19, which older Quotio CLI binaries cannot read.

## Widgets, privacy and data

Add Quotio using the system Home Screen or Lock Screen editor. Configure each
instance with a host/account/window and used/remaining preference. Tapping opens the
same account. Widgets never merge identities between computers.

WidgetKit chooses update times. Cached data, host sleep, unavailable VPN and expired
credentials are visible states. Pull-to-refresh in the app reads a snapshot; it does
not trigger a provider refresh with a read-only token. Missing quota is not zero;
reset deadlines do not imply quota has returned to 100%.

Charts use provider-reported dates and the 30 most recent reported buckets, not an
invented continuous 30-day history. Privacy mode blurs account names and email addresses
in the app, VoiceOver and widget configuration. Lock Screen widgets do not display account names.
Already-rendered system widget content may persist until iOS processes a reload.

Removing a host deletes its local token/cache; revoke on the computer to invalidate
access. Device grants expire after 30 days by default. Keychain credentials are
ThisDeviceOnly, available after first unlock, and do not sync through iCloud.

## Windows and release status

The native Windows backend includes per-user DPAPI storage, file locking and
atomic replacement. Runtime verification remains pending on Windows. Cross-compilation
on macOS is not a DPAPI or Windows-device test; do not advertise Windows support
before those checks pass.

Before TestFlight: supply the signing team and group provisioning, validate on a
physical iPhone over LAN and VPN, exercise widget timing outside developer mode,
verify fresh/revoked credentials on each host OS, archive and inspect entitlements.
No APNs, Live Activities or task-progress source is included in this release.

The iOS app icon is a 1024 × 1024 RGB PNG with no alpha channel or transparent
pixels. The icon transparency blocker is resolved; App Store validation is still
required for the archived build.
