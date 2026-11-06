## What is this?

Routey is a Mac menu bar app with two proxies in one, each with its own tab, server and
switch: Shadowsocks for the apps the user picks, and VLESS over REALITY for every other app. It is
a transparent proxy, a Network Extension running as a system extension: macOS offers it every new
outgoing connection along with the app that opened it, and it takes those of the chosen apps
through Shadowsocks, the rest through VLESS when it is on, TCP and UDP, and hands back what
neither takes. Shadowsocks, VLESS, REALITY and its TLS 1.3 are written here in Swift on
Network.framework and CryptoKit. It is under the MIT license.

| Part | Where | What it does |
| --- | --- | --- |
| Core (`Sources/ProxyCore`) | In both | Shadowsocks and VLESS: the links, the protocols, the connections to the servers; the config. No NetworkExtension, so it is tested on its own |
| Proxy (`Sources/RouteyProxy`) | The system extension | Picks the flows to take and relays each through its server |
| App (`Sources/Routey`) | The user's Mac | Installs the extension, turns each proxy on and off, the menu bar item and the panel |

## Repo Structure:

### Sources/ProxyCore

- `Server.swift`: the ciphers (`EncryptionMethod`) and a server read from an `ss://` link: SIP002,
  with the userinfo in base64 or percent-encoded, and the old all-base64 links. The AEAD ciphers'
  key is the password through `EVP_BytesToKey`; 2022's is the base64 pre-shared key.
- `Crypto.swift`: AES-GCM and ChaCha20-Poly1305, session keys (HKDF-SHA1 for AEAD, BLAKE3 for
  2022), the nonce counter, and AES on single blocks for 2022's UDP headers.
- `BLAKE3.swift`: BLAKE3 after the reference implementation, for 2022's `derive_key`.
- `Address.swift`: a target as a SOCKS5 address, and which ones are local (this Mac, private
  networks), which always go direct.
- `Stream.swift`: TCP. `RequestEncoder` writes the salt, the target (2022's request header, padded
  when there is no data yet) and length-prefixed chunks; `ResponseDecoder` reads the server's,
  checking 2022's response header.
- `Packet.swift`: UDP. A salt per packet for AEAD; a session with numbered packets for 2022.
- `Tunnel.swift`: `StreamTunnel` and `DatagramTunnel`, what a TCP connection and a UDP flow through
  a server do, and `Upstream`, the server one goes through. `TunnelConnection` and `PacketTunnel`
  are Shadowsocks's, over `NWConnection`. Everything of one runs on one queue.
- `TLS.swift`: the server name in a TLS ClientHello.
- `TLS13.swift`: TLS 1.3's key schedule and records, for REALITY.
- `REALITY.swift`: REALITY's handshake as the client: Safari 26's ClientHello (X25519MLKEM768 and
  X25519 key shares, which REALITY servers require), whose session ID carries the version, time
  and short ID sealed under a key from the server's public key; the server proves it has that
  key with the HMAC in its certificate's signature. ML-KEM is CryptoKit's, so VLESS needs macOS 26.
- `VLESS.swift`: a server read from a `vless://` link (REALITY over TCP, the xtls-rprx-vision flow
  or none), the request header, and Vision: padded blocks while the app's TLS shakes hands, then
  raw TCP once its TLS 1.3 carries data.
- `VLESSTunnel.swift`: `VLESSConnection`, a TCP connection or one UDP target's packets through the
  server, and `VLESSPacketTunnel`, a UDP flow with a connection per target.
- `DNSLookup.swift`: a DNS query asked of 1.1.1.1 over TCP through either server.
- `ProxyConfig.swift`: the config (Shadowsocks's link and the apps' bundle identifiers, which also
  match their helpers; VLESS's link; whether each is on), saved and imported as JSON, which also
  reads the files from before VLESS; which server a flow goes through; the messages between the
  app and the proxy, and the totals for each server.

### Sources/RouteyProxy

- `TransparentProxyProvider.swift`: claims every outgoing flow from macOS, then takes those whose
  target isn't local: through Shadowsocks when its signing identifier is a chosen app's, through
  VLESS otherwise when it is on. The config comes with the proxy's configuration and, while it
  runs, in a message from the app. Answers the app's requests for the totals.
- `Relays.swift`: one relay per flow. TCP waits briefly for the app's first data and sends it with
  the request; a TLS server name in it replaces an IP target, so the server resolves the name. UDP
  carries each datagram to its own target and ends after two idle minutes.

### Sources/Routey

- `ProxyController.swift`: the system extension (installed, or replaced by a new version, at each
  launch once the proxy exists) and the `NETransparentProxyManager`, connected on demand so macOS
  keeps it up through restarts and network changes. While the panel shows: each server's speeds
  from the proxy's totals every second, latency as the time to open a TCP connection to it.
- `AppModel.swift`: the config, saved in the defaults; the two switches (the proxy runs while
  either is on); the login item; importing and exporting.
- `StatusItemController.swift`: the menu bar item, drawn from Lucide's `route` (`LucideRoute.swift`),
  dimmed while the proxy isn't connected. A click drops the panel down; a right click shows a
  short menu.
- `SettingsView.swift`: the panel, a grouped SwiftUI form of stock controls with plain names, with a
  tab for Shadowsocks and one for VLESS.
- `Updater.swift`: checks the latest GitHub release at launch and every six hours, and installs it
  when asked: it checks the download is signed by the team (44R7KF7645), swaps the app and
  restarts it.

### Resources, assets and scripts

- `Resources/AppIcon.icon`: the app icon, made for Icon Composer: Lucide's `route`, white on a
  dark tile. `assets/favicon.svg` is the same icon as a flat SVG.
- `Resources/App.entitlements`, `Resources/Proxy.entitlements`: what each is allowed; the
  extension is sandboxed. `Resources/Profiles`: their Developer ID provisioning profiles, which
  grant the Network Extension. They aren't secret: they ship inside the app. The `routey-ios*`
  ones are the App Store profiles for the coming iOS app, its tunnel and its widgets, which share
  the app group `group.org.routey.routey`.
- `scripts/build-app.sh`: builds `build/Routey.app` with the extension in
  `Contents/Library/SystemExtensions`, universal, signed with `SIGN_IDENTITY` and the profiles,
  or ad hoc without it (then macOS won't load the extension).
- `scripts/release-version.sh`: the version of a commit: `VERSION` and the number of commits.
- `scripts/install.sh`: installs the latest release into /Applications from Terminal.

## General Rules:

- Keep it simple. Do not overcomplicate things.
- The proxy must be fast. Flows of other apps are handed back at once; nothing slow runs where
  macOS waits on the provider; each relay works on its own queue.
- Shadowsocks and VLESS belong in `ProxyCore`, where they are tested against real servers, not in
  the proxy.
- No logs of any kind, anywhere: nothing about connections is written, not even to the unified log.
- The app looks like the current macOS: stock AppKit and SwiftUI controls in the system's
  colours on tinted glass, no colours of our own, the Lucide route for the app.
- Do not leave paragraphs of comments on top of the code. Prefer clear names; keep the comments
  that are needed concise. Comments move with the code.
- Use guard statement patterns in any code you write.
- Do not write useless tests; tests cover input/output behaviour.
- Reinvent the wheel but do not reinvent the car. A simple problem gets no new library.
- Do not insert yourself into our code, commits or PRs in any way.
- Never commit or push unless asked to.
- After you make code changes, run the checks below and fix what they raise.

## Development

Needs a Mac with Xcode 26 or later (for the icon), and macOS 15 or later.

    scripts/build-app.sh --open      # builds and opens build/Routey.app
    swift test                       # the core's tests

`brew install shadowsocks-rust xray` for the tests that talk to real servers (`ssserver`, and Xray
with REALITY in front of VLESS); without them they are skipped. macOS only runs the extension
signed with the Developer ID and its profile, from an app in /Applications: for a local build,
import the certificate from `~/apple-signing` into a keychain, build with `SIGN_IDENTITY` (and
`SIGN_KEYCHAIN`), and copy the app to /Applications.

`build.yml` tests and builds pull requests. On `main`, `release.yml` tests, builds, signs,
notarizes and publishes the app as a GitHub release; it needs the repository's signing secrets
(`APPLE_CERTIFICATE` and `APPLE_CERTIFICATE_PASSWORD`, the Developer ID Application certificate as
a base64 .p12 and its password; `APPLE_API_KEY`, `APPLE_API_KEY_ID` and `APPLE_API_ISSUER_ID`, an
App Store Connect API key) and the profiles. The secrets come from `~/apple-signing` on the dev
machine, whose README.md says which file is which secret.

## Commit Messages

Commit messages start with the part of the system they touched, followed by a short imperative
sentence describing the change:

    core: Speak Shadowsocks 2022 over UDP
    proxy: Send TLS server names to the server
    app: Show the server's latency

The parts are `core`, `proxy` and `app`. Use `ci` for the workflows and scripts and `docs` for
README.md and AGENTS.md.

The title should be concise. The description explains the work in more detail (only if
required) while still being concise. Use simple language, do not try to sound smart.
