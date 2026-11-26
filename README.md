<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/banner-dark.svg">
  <img src="assets/banner-light.svg" width="100%" alt="Kira — the quiet power tweak for Telegram on iOS">
</picture>

<p align="center">
  <img src="https://img.shields.io/badge/version-2.0-111111?style=for-the-badge&labelColor=000000" alt="Version 2.0">
  <img src="https://img.shields.io/badge/Telegram-13.1.1-229ED9?style=for-the-badge&logo=telegram&logoColor=white&labelColor=1a1a1a" alt="Telegram 13.1.1">
  <img src="https://img.shields.io/badge/iOS-14%2B-555555?style=for-the-badge&logo=apple&logoColor=white&labelColor=1a1a1a" alt="iOS 14+">
  <img src="https://img.shields.io/badge/jailbreak%20%C2%B7%20sideload-supported-2ea043?style=for-the-badge&labelColor=1a1a1a" alt="Jailbreak and sideload">
</p>

<p align="center">
  <a href="#-a-quick-look">Screenshots</a> &nbsp;•&nbsp;
  <a href="#-features">Features</a> &nbsp;•&nbsp;
  <a href="#-installation">Installation</a> &nbsp;•&nbsp;
  <a href="#-compatibility">Compatibility</a> &nbsp;•&nbsp;
  <a href="#-how-it-works">How it works</a> &nbsp;•&nbsp;
  <a href="#-building-from-source">Build</a>
</p>

> [!TIP]
> **Open the menu:** Telegram → **Settings** → long-press **Ask a Question**.

<br>

## 📸 A quick look

<table align="center">
  <tr>
    <td align="center" width="34%"><img src="Screenshots/menu.jpg" alt="Kira menu"></td>
    <td align="center" width="66%"><img src="Screenshots/edit-history.jpg" alt="Edit history"></td>
  </tr>
  <tr>
    <td align="center"><sub><b>One quiet menu</b> — everything grouped, with search</sub></td>
    <td align="center"><sub><b>Edit history</b> — every version, changes highlighted</sub></td>
  </tr>
  <tr>
    <td align="center" colspan="2"><img src="Screenshots/chat-marks.jpg" width="72%" alt="Deleted and edited marks"></td>
  </tr>
  <tr>
    <td align="center" colspan="2"><sub><b>🗑 deleted</b> and <b>✏️ edited</b> marks right in the chat — tap them for details</sub></td>
  </tr>
</table>

<br>

## ✨ Features

<table>
  <tr>
    <td valign="top" width="50%">

### 👻 Ghost Mode
- **Stay invisible** — no online status, no read receipts for messages and stories
- **Hide activity** — typing, recording, uploading and every other status, each on its own switch
- **Read on reply** — chats stay unread until you answer
- **Keep voice unplayed** — listen without marking as played
- **Exceptions** — switch ghost mode off for a chat from its profile

</td>
    <td valign="top" width="50%">

### 💬 Messages
- **Continue downloading in background (iOS 26+)** — start a document download, open Messages, select the active file; the system schedules a continued-processing task and shows progress. Requires the prepared IPA and MtProtoKit, not Rust. Experimental; no silent audio. See [background downloads](README_BACKGROUND_DOWNLOAD26.md).
- **Anti-Revoke** — deleted messages stay, marked with 🗑 and the exact time
- **Edit history** — ✏️ on edited messages, every version with a diff
- **Message log** — all deleted & edited messages in one place
- **Deletion banner** — optional pop-up when someone deletes a message
- **Profile changes log** — names, usernames and photos
- **Anti self-destruct** & **anti auto-delete**
- **Forward without author** · **no screenshot alerts**

</td>
  </tr>
  <tr>
    <td valign="top">

### 🔓 Content & Stories
- **Save restricted media** — forward, copy and save from protected channels, groups and chats
- **No ads** and **no proxy sponsor channel**
- **Auto proxy** — uses the private gateway after one-time device activation; automatic connection and server rotation remain available in the menu
- **App Store–restricted chats** become visible
- **Save deleted stories**, **unlock story saving**, **hide stories**

</td>
    <td valign="top">

### 🧰 Media, Calls & Extras
- **Send audio as voice**
- **Confirm calls** — no accidental dialing
- **Manual call recording** — audio and video with explicit user confirmation; normal video calls only
- **Fake location** — any point on the map
- **`#` on profiles** — ID and estimated sign-up year
- **Settings export / import**, 10 languages, search
- **Diagnostics log** for bug reports

</td>
  </tr>
</table>

<br>

## 📦 Installation

### 📲 Sideload — no jailbreak

Use the IPA distributed by the maintainer of this Kira edition.

> [!IMPORTANT]
> Kira is **already inside** the IPA — sign it as usual and **don't add the dylib again**.
> The **sideload fix is built in**, so a separate “sideload fixer” dylib isn't needed.

> [!NOTE]
> Notifications with message text work when your signing supports **App Groups**.

**Injecting Kira yourself** (decrypted IPA required) — into the app *and* its notification extension:

```bash
python3 tools/inject_ipa.py Telegram.ipa --dylib packages/Kira.dylib
```

### 🔓 Jailbreak

Install the `.deb` for this Kira edition with your package manager, then restart Telegram.

<br>

## 🧩 Compatibility

| | App | Status |
|:-:|---|---|
| ✅ | **Telegram 13.2** | Everything works |
| ✅ | **Turrit 1.5.8** | Everything works |
| ✅ | **Swiftgram 13.1.2** | Everything works |
| ⚠️ | **Nagram 13.1.1** | Same API as the others, not fully tested yet |

> [!WARNING]
> With the **Rust MTProto** engine enabled in Telegram's Debug menu, network features can't work. Kira shows a warning in its menu when that happens.

<br>

## 🧠 How it works

Kira sits between Telegram and the network. It reads what the server sends, adjusts it, and hands it back, so Telegram itself does the rest — no private Swift hooks, which is why it works without a jailbreak.

```mermaid
flowchart LR
    S(["☁️ Telegram servers"]) <--> M["MtProtoKit"]
    M <--> L{{"⚡ Kira"}}
    L --> T["📱 Telegram app"]
    L -. "keeps deleted messages<br/>unlocks protected content<br/>records edits" .-> T
    N["🔔 Notification extension"] -->|shared App Group| D[("💾 Account data")]
    T --> D
```

<br>

## 🛠 Building from source

<details>
<summary><b>Build the tweak</b></summary>
<br>

Requires [Theos](https://theos.dev).

```bash
make package FINALPACKAGE=1
```

The `.deb` lands in `packages/`, the dylib in `.theos/_/Library/MobileSubstrate/DynamicLibraries/`.

</details>

<details>
<summary><b>Update for a new Telegram version</b></summary>
<br>

Regenerate the embedded API from Telegram-iOS's `swift_scheme.tl` — not `schema.json`, which lags behind:

```bash
python3 tools/gen_api.py <Telegram-iOS>/submodules/TelegramApi/swift_scheme.tl Sources/tgapi/api_sources
```

For a fork, `tools/extract_schema.py` recovers the schema straight from its app bundle.

</details>

<br>

## ❤️ Support

Kira is free. If you'd like to support development, open **Kira → Support** in the app for donation wallets:

<p>
  <img src="https://img.shields.io/badge/TON-0098EA?style=flat-square&logo=ton&logoColor=white" alt="TON">
  <img src="https://img.shields.io/badge/BTC-F7931A?style=flat-square&logo=bitcoin&logoColor=white" alt="Bitcoin">
  <img src="https://img.shields.io/badge/ETH-3C3C3D?style=flat-square&logo=ethereum&logoColor=white" alt="Ethereum">
  <img src="https://img.shields.io/badge/SOL-9945FF?style=flat-square&logo=solana&logoColor=white" alt="Solana">
  <img src="https://img.shields.io/badge/USDT-26A17B?style=flat-square&logo=tether&logoColor=white" alt="Tether">
</p>

<details>
<summary><b>⚠️ Disclaimer</b></summary>
<br>

Kira is an **independent modification** of the Telegram app. It is **not affiliated with, authorized or endorsed by Telegram Messenger LLP** or any of its affiliates. It is made for personal and educational use — use it at your own risk; the author takes no responsibility for any consequences of using it.

</details>

### 🙏 Acknowledgements
- Based on the original [Lead by w3ltyyy](https://github.com/w3ltyyy/lead); Kira is a modified fork.
- **chocolate fluffy** — for the core code this project grew from
- A fork of [Aj3radi/TGExtra](https://github.com/Aj3radi/TGExtra)

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/footer-dark.svg">
  <img src="assets/footer-light.svg" width="100%" alt="Kira">
</picture>

## 🌐 Auto proxy — private gateway

The app obtains one proxy per authorized request through the configured HTTPS gateway.
On first use, open the Kira proxy settings, select the activation action, and enter a one-time
code supplied by the service administrator. The device token is stored in Keychain; the
short-lived session and currently selected proxy stay in memory.

The auto-proxy switch is enabled by default, subject to successful activation.
Refresh checks the assigned server and advances past unreachable servers; Change Proxy
requests the next server. The UI shows only the ordinal server label. The public
`proxies.json` is an empty legacy placeholder, and there are no embedded backup proxy links.

The gateway origin is configured in `Sources/tgapi/UI/KiraProxyGateway.m`;
never place administrative or activation credentials in the source.

A proxy manually enabled inside Telegram's own settings takes priority. WARP remains an
independent opt-in call-connectivity feature.

