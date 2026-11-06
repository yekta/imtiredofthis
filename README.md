<img src="assets/favicon.svg" width="64" height="64" alt="">

# Routey

Two proxies in one menu bar app: **Shadowsocks** for the Mac apps you choose, and **VLESS** over REALITY for every other app. Each has its own tab, its own server and its own switch. Under the MIT license.

- **Shadowsocks, per app.** Pick apps from the menu; they and their helpers go through your Shadowsocks server, over TCP and UDP, so voice and video calls work too.
- **VLESS, for the whole Mac.** Paste the `vless://` link your Xray server gave you and turn it on: every app goes through it, except the ones Shadowsocks sends. With both off, every app connects as usual.
- **Native.** macOS's own per-app proxy (a Network Extension), not a VPN or a TUN device. No root helper, no Go core: Shadowsocks, VLESS, REALITY and its TLS 1.3 are written in Swift on Network.framework and CryptoKit.
- **No logs.** Nothing about your connections is written anywhere.
- **Stays on.** macOS keeps the proxy running through restarts, sleep and network changes, even with the app quit, until you turn it off.
- **Past DNS tampering.** When an app opens a TLS connection, the server name it asks for goes to your server, which looks it up itself.
- **Simple.** One panel with a tab for each: on or off, live upload, download and latency, your server, your apps.

Shadowsocks ciphers: `aes-128-gcm`, `aes-256-gcm`, `chacha20-ietf-poly1305`, `2022-blake3-aes-128-gcm` and `2022-blake3-aes-256-gcm`. Plugins (obfs, v2ray-plugin) aren't supported.

VLESS: REALITY over TCP (`security=reality`, `type=tcp`), with the `xtls-rprx-vision` flow or none, which is what Xray's usual setup gives you. Its TLS looks like Safari's, with the post-quantum X25519MLKEM768 key exchange REALITY servers now require, so VLESS needs macOS 26 or later. With Vision, UDP to port 443 (QUIC) is left out, as Xray does, so browsers use TCP.

## Install

Download `Routey.zip` from the [latest release](https://github.com/yekta/routey/releases/latest), unzip it and move **Routey** to Applications. Or paste this in Terminal, which does the same and opens it:

```sh
curl -fsSL https://raw.githubusercontent.com/yekta/routey/main/scripts/install.sh | sh
```

Then, from its menu bar icon:

1. In the Shadowsocks tab, paste your server's `ss://` link and add the apps that should go through it. Or, in the VLESS tab, paste your `vless://` link.
2. Turn it on with the tab's switch. The first time, macOS asks you to allow the proxy: in **System Settings → General → Login Items & Extensions → Network Extensions**, turn on Routey, then allow it to add its proxy configuration.

It checks for new versions by itself and offers them in its menu and panel: **Install and Restart** updates it in place.

## Config file

**Export Config…** and **Import Config…** save and load the setup as JSON. Importing brings the servers and apps; what is on stays as it is.

```json
{
  "shadowsocks": {
    "on": true,
    "server": "ss://2022-blake3-aes-256-gcm:YOUR-KEY@203.0.113.7:8388#Frankfurt",
    "apps": ["com.hnc.Discord"]
  },
  "vless": {
    "on": false,
    "server": "vless://YOUR-UUID@203.0.113.8:443?security=reality&sni=www.samsung.com&pbk=YOUR-PUBLIC-KEY&sid=YOUR-SHORT-ID&flow=xtls-rprx-vision&type=tcp#Hetzner"
  }
}
```

The older files, with just `server` and `apps`, still import. `apps` are bundle identifiers; each also covers the identifiers that start with it and a dot, like Discord's `com.hnc.Discord.helper`. Command-line tools work too, by their signing identifier (`com.apple.curl`). Connections to this Mac and your own network always go direct.

## Building

Needs Xcode 26 or later.

```sh
scripts/build-app.sh --open   # builds build/Routey.app and opens it
swift test                    # tests the core, and talks to real servers if shadowsocks-rust and xray are installed
```

macOS only loads the proxy extension when it is signed with a Developer ID and its provisioning profile, and the app is in /Applications. Every push to `main` is built, signed, notarized and published as a [GitHub release](https://github.com/yekta/routey/releases).

## License

MIT. The icon is [Lucide](https://lucide.dev)'s `route`, under the ISC license.
