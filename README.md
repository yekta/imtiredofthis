<img src="assets/favicon.svg" width="64" height="64" alt="">

# imtiredofthis

Sends the Mac apps you choose through your Shadowsocks server, and nothing else. A menu bar app, under the MIT license.

- **Per app.** Pick apps from the menu; they and their helpers go through the server, over TCP and UDP, so voice and video calls work too. Every other app connects as usual and never passes through it.
- **Native.** macOS's own per-app proxy (a Network Extension), not a VPN or a TUN device. No root helper, no Go core: Shadowsocks is written in Swift on Network.framework and CryptoKit.
- **Stays on.** macOS keeps the proxy running through restarts, sleep and network changes, even with the app quit, until you turn it off.
- **Past DNS tampering.** When an app opens a TLS connection, the server name it asks for goes to your server, which looks it up itself.
- **Simple.** One panel: on or off, live upload, download and latency, your server, your apps.

Ciphers: `aes-128-gcm`, `aes-256-gcm`, `chacha20-ietf-poly1305`, `2022-blake3-aes-128-gcm` and `2022-blake3-aes-256-gcm`. Plugins (obfs, v2ray-plugin) aren't supported.

## Install

Download `imtiredofthis.zip` from the [latest release](https://github.com/yekta/imtiredofthis/releases/latest), unzip it and move **imtiredofthis** to Applications. Or paste this in Terminal, which does the same and opens it:

```sh
curl -fsSL https://raw.githubusercontent.com/yekta/imtiredofthis/main/scripts/install.sh | sh
```

Then, from its menu bar icon:

1. Paste your server's `ss://` link.
2. Add the apps that should go through it.
3. Turn it on. The first time, macOS asks you to allow the proxy: in **System Settings → General → Login Items & Extensions → Network Extensions**, turn on imtiredofthis, then allow it to add its proxy configuration.

It checks for new versions by itself and offers them in its menu and panel: **Install and Restart** updates it in place.

## Config file

**Export Config…** and **Import Config…** save and load the setup as JSON:

```json
{
  "server": "ss://2022-blake3-aes-256-gcm:YOUR-KEY@203.0.113.7:8388#Frankfurt",
  "apps": ["com.hnc.Discord"]
}
```

`apps` are bundle identifiers; each also covers the identifiers that start with it and a dot, like Discord's `com.hnc.Discord.helper`. Command-line tools work too, by their signing identifier (`com.apple.curl`). Connections to this Mac and your own network always go direct.

## Building

Needs Xcode 26 or later.

```sh
scripts/build-app.sh --open   # builds build/imtiredofthis.app and opens it
swift test                    # tests Shadowsocks, and talks to a real server if shadowsocks-rust is installed
```

macOS only loads the proxy extension when it is signed with a Developer ID and its provisioning profile, and the app is in /Applications. Every push to `main` is built, signed, notarized and published as a [GitHub release](https://github.com/yekta/imtiredofthis/releases).

## License

MIT. The icon is [Lucide](https://lucide.dev)'s `route`, under the ISC license.
