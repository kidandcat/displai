# Minerva

<p align="center"><img src="docs/orb.gif" width="220" alt="Minerva's presence orb"></p>

A voice-first assistant for macOS. You talk; it answers with a short spoken sentence and shows the
rest on screen. There is no chat window: when nothing is shown, the window is an audio-reactive
"presence" orb.

The brain is a coding agent you already pay for, run headless underneath the app on your own install
and login: **Claude Code**, **Google Antigravity** or **OpenAI Codex**. Minerva gives it a display,
your Mac's tools and its own long-term memory through an MCP server embedded in the app. You can
connect several of them and set a fallback order: when one hits its usage limit, Minerva carries on
with the next and comes back when the limit resets. Speech recognition and synthesis run locally.

The same Flutter app on Android turns your phone into Minerva's mic, speaker and screen. Everything is
still processed and done on the Mac.

> Status: personal project under active development. macOS (Apple Silicon tested) and Android only.
> UI and voice in English and Spanish.

## Quick start

1. **Install a brain.** Minerva runs on an agent CLI you already have a subscription for. Install
   at least one and sign in once in a terminal:
   - Claude Code: `npm i -g @anthropic-ai/claude-code`, then `claude` and `/login`.
   - Codex: `brew install --cask codex` (or `npm i -g @openai/codex`), then `codex login`.
   - Antigravity: install the `agy` CLI from [antigravity.google](https://antigravity.google), then
     run `agy` and sign in with Google.

   The CLI must be on your login shell's `PATH` (check with `which claude`, `which codex` or
   `which agy`).
2. **Install Minerva on the Mac.** Download `Minerva-<version>-macos.zip` from
   [Releases](https://github.com/kidandcat/minerva/releases/latest), unzip it and drag `Minerva.app`
   to Applications. Release builds are not notarized, so the first time remove the quarantine flag:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Minerva.app
   ```

   Open Minerva. It downloads the speech models (about 600 MB) and asks for the **Microphone**. For
   computer use, allow it in System Settings → Privacy & Security → **Accessibility** and
   **Screen Recording**, then reopen it. With an unsigned build, macOS may ask again after each update:
   remove Minerva from those lists and add it back.
3. **Pick the brain.** Click the model in the status bar. In **Conversation** (and **Workers**)
   choose the provider and model; under **Fallbacks** add the other providers you have, in order.
   The **Providers** tab shows which ones are ready.
4. **Talk.** Just speak; you can interrupt Minerva while it answers.
5. **Phone (optional).** Download `Minerva-<version>-android-arm64.apk` from the same release on an
   Android phone (arm64) and install it (allow installing from your browser or file manager). Open it
   and scan the QR code from the phone button on the Mac. To see Minerva's orb over other apps, allow
   "display over other apps" from its settings screen. Release APKs are not signed with a stable key
   yet, so to update, uninstall the old one first.

**From source** instead: install Flutter (stable) and Xcode, and Go for the webhook helper, then

```sh
git clone https://github.com/kidandcat/minerva && cd minerva/app
flutter pub get
flutter build macos --release   # build/macos/Build/Products/Release/Minerva.app
flutter build apk --release --target-platform android-arm64
```

See [Build and run](#build-and-run) for development, the login service and the relay.

## Features

- **Local speech**: Silero VAD, NVIDIA Parakeet TDT v3 speech recognition (25 European languages) and
  Supertonic 3 text-to-speech (31 languages, ten voices) through
  [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). No cloud speech. Models are downloaded on first
  run, not bundled.
- **Full duplex**: echo-cancelled audio (macOS voice processing), so you can interrupt Minerva by
  talking over it.
- **AI-controlled display**: the brain shows cards, tables, stats, forms, video, or HTML pages it writes
  itself (games, simulations, custom charts), rendered from a fixed themed catalog
  ([A2UI](https://a2ui.org) via Flutter GenUI). Every item gets a number, so "the second one" works by
  voice.
- **Computer use**: shell commands, files, screenshots, the accessibility tree, mouse and keyboard, apps
  and windows. While it works in other apps, Minerva shrinks to a floating orb.
- **Phone remote (Android)**: pair with a QR code; the phone becomes the mic, speaker and display.
  Desktop and phone talk through a small relay with end-to-end encryption, so the relay only forwards
  ciphertext. The phone only listens, speaks and shows: every action still happens on the Mac.
  Minerva can be the phone's default digital assistant and show a floating orb over other apps.
- **Telegram**: chat with Minerva by text through your own bot when you can't talk. Voice notes and
  audio files you send there are transcribed locally by the same speech recognizer. Answers in a
  Telegram turn are written, not spoken.
- **Webhooks**: third parties (GitHub, Stripe, home automation…) can call your Mac at a per-webhook
  secret URL; each request reaches the brain as a message. TLS is terminated on the Mac, not on the
  relay.
- **Memory and continuity**: one continuous conversation across restarts, full searchable history,
  memories, and skills (reusable procedures as `SKILL.md` files).
- **Workers**: background agent sessions (on any of the providers) for longer tasks, which report back
  when done.
- **Routines**: one-time, daily or interval prompts (reminders, recurring checks).
- **Projects**: plain folders with a `README.md`; workers can run inside them.
- **Credential vault**: the brain uses secrets through `{{vault:name.field}}` placeholders without ever
  seeing their values; tool results are scrubbed.

## Architecture

```
 mic ─▶ VAD ─▶ STT ─▶ ┌──────────── Minerva (Flutter, macOS) ────────────┐
                      │ session manager ◀──▶ claude -p │ agy acp │ codex app-server
 speaker ◀── TTS ◀────│ embedded MCP server (display, Mac, memory,       │
                      │   workers, routines, vault, webhooks, phone…)    │
 display ◀────────────│                                                  │
                      └───────┬──────────────────────┬───────────────────┘
                              │ E2E-encrypted        │ TLS passthrough
                         relay (Go) ─────────── minerva-webhooks helper
                              │
                       Android app (mic, speaker, display)
```

Minerva is both the reader of the brain's output stream and the MCP server that runs its tools, so it
can speak sentences and render views while they are still streaming. All capabilities live in
Minerva's MCP server, which keeps the brain pluggable.

The full design, with measured latencies and the security model, is in
[docs/design.md](docs/design.md).

| Path | What it is |
|---|---|
| `app/` | The Flutter app: macOS desktop and Android remote (`lib/`, native code in `macos/Runner` and `android/`) |
| `relay/` | Go relay that pairs desktop and phone, plus the TLS passthrough for webhooks |
| `relay/cmd/minerva-webhooks` | Webhook helper bundled in the macOS app |
| `docs/design.md` | Design document |
| `spike/` | Throwaway latency and audio experiments |

## Requirements

- macOS 12 or later (developed on Apple Silicon), with Xcode.
- [Flutter](https://flutter.dev) (stable, Dart ≥ 3.13).
- At least one brain provider installed and signed in: Claude Code, the Antigravity CLI or the Codex
  CLI (see [Brain providers](#brain-providers)).
- Go ≥ 1.25 to build the relay and the webhook helper (without Go the app still builds, without
  webhooks).
- About 600 MB of disk for the speech models, downloaded on first run.
- For the phone remote: an Android phone and the Android SDK.

## Brain providers

Minerva has no API keys of its own: each provider is the agent's own CLI, on its own subscription and
login. All three get the same tools, prompt, memory and conversation; pick by preference, plan or
model.

| Provider | CLI | Subscription | Install | Sign in | How Minerva runs it |
|---|---|---|---|---|---|
| **Claude** | [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude`) | Claude Pro / Max | `npm i -g @anthropic-ai/claude-code` (or the native installer) | `claude`, then `/login` | `claude -p` with stream-json |
| **Antigravity** | Antigravity CLI (`agy`) | Google Antigravity | see [antigravity.google](https://antigravity.google) | `agy`, sign in with Google | `agy acp` (Agent Client Protocol) |
| **Codex** | [Codex CLI](https://developers.openai.com/codex/cli) (`codex`) | ChatGPT Plus / Pro / Business | `brew install --cask codex` or `npm i -g @openai/codex` | `codex login`, sign in with ChatGPT | `codex app-server` (JSON-RPC) |

The CLIs must be on the `PATH` of your login shell. Minerva starts them itself; you only sign in once
in a terminal. Each one keeps its conversation across restarts (session resume).

**Choosing a provider and model.** Click the model in the status bar (or open the phone's settings).
The **Conversation** and **Workers** tabs each have a provider switch, the models that provider lists
(read from the installed CLI, never hard-coded), the effort and, where the model has it, fast mode. The
conversation and the workers can run on different providers.

**Usage.** The start of the status bar has a dial per provider the conversation and the workers run
on: its logo inside a ring per plan limit (outermost the five hours, then the week, then a model's own
week), filled as far as it is spent. The color is the pace: green while the limit lasts until its reset,
orange when it ends close to it (90–110 % projected), red when it runs out before (or already has).
Hovering a dial enlarges it into a card with each limit's percent, reset, projection and, when it runs
out early, around when. Claude's comes from Claude Code's sign-in (the same usage endpoint as its
`/usage`), Codex's from its app server (`account/rateLimits/read`) and Antigravity's from
`agy -p /usage`. They are read every five minutes, less often after a failed read; a provider that
can't be read is hidden.

**Fallbacks.** Like OpenBot, Minerva can use several subscriptions at once.
Under each tab, **Fallbacks** is an ordered list of provider and model (one per provider). Minerva runs
on the first one that can answer. When a provider reports a usage limit, rate limit or quota error, or
a lost login, Minerva marks it out (until the reset time the CLI gives, or for a while when it gives
none), says so, and resends the message to the next fallback; a worker hands its task over the same
way. It goes back to your preferred choice once the limit is over. The **Providers** tab shows each
provider's status (ready, not installed, limited until when) and what is running on it. Switching
providers mid-conversation keeps Minerva's own history and memory, but the new agent starts a fresh
context and reads back what it needs from the history.

## Build and run

### macOS app

```sh
cd app
flutter pub get
flutter run -d macos            # development
flutter build macos --release   # build/macos/Build/Products/Release/Minerva.app
```

On first start Minerva downloads the speech models and asks for the microphone. Computer use needs the
**Accessibility** and **Screen Recording** permissions (System Settings → Privacy & Security).

To run it as a login service (hidden at login, menu bar item, restarted after a crash):

```sh
tool/install_macos_service.sh             # installs /Applications/Minerva.app and a LaunchAgent
tool/install_macos_service.sh --uninstall # removes the LaunchAgent
```

The script signs the app with an Apple Development identity so macOS keeps the permission grants
across rebuilds. It is set up for the maintainer's team: change `team=` in the script (or set
`MINERVA_SIGN_IDENTITY`) for your own.

### Android app

```sh
cd app
flutter build apk --release --target-platform android-arm64
```

Install the APK, open it and scan the QR code from the desktop's phone button. To see Minerva's orb
over other apps, allow "display over other apps" from its settings screen.

Release builds are signed with the debug key unless `android/key.properties` (`storeFile`,
`storePassword`, `keyAlias`, `keyPassword`; git-ignored) or the `MINERVA_KEYSTORE_FILE`,
`MINERVA_KEYSTORE_PASSWORD`, `MINERVA_KEY_ALIAS` and `MINERVA_KEY_PASSWORD` environment variables
point to a release keystore.

### Relay

The app uses a public relay at `wss://minerva.kidandcat.com` by default. To run your own:

```sh
cd relay
go test ./...
go run . -addr 0.0.0.0:8094          # add -tap to log every frame as the relay sees it
```

and start the desktop with `MINERVA_RELAY=ws://<host>:8094`. `relay/deploy/` has a systemd unit, a
deploy script and the Caddy configuration (including SNI passthrough for webhooks).

### Releases

Pushing a `v*` tag runs [`.github/workflows/release.yml`](.github/workflows/release.yml): it builds
`Minerva.app` (zipped) on a macOS runner and the arm64 APK on Linux, and publishes both on a GitHub
Release, with the version taken from the tag (`git tag v1.2.3 && git push origin v1.2.3`). Running
the workflow by hand only builds them, as workflow artifacts. It needs no secrets: without them the
app is ad-hoc signed and the APK debug-signed. Optional repository secrets:

| Secret | Effect |
|---|---|
| `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD` | Developer ID Application certificate (base64 `.p12`) to sign the app |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | Notarize and staple the signed app (app-specific password) |
| `ANDROID_KEYSTORE`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Release keystore (base64 `.jks`) for the APK, so updates install over older versions |

### Tests

```sh
cd app && flutter test
cd relay && go test ./...
```

## Configuration

Most settings are in the app: the status bar (and the phone's settings screen) has the conversation and
worker providers and models with effort, speed and fallbacks, the voice, the language, credentials
and webhooks. Models are whatever your installed agents offer. Telegram is set up by saving a vault credential
named `telegram` with the bot's `token` and your Telegram user id as `chat_id` (messages from other
chats are ignored).

Environment variables:

| Variable | Effect |
|---|---|
| `MINERVA_DATA_DIR` | Data directory (default `~/Library/Application Support/com.kidandcat.minerva/`) |
| `MINERVA_MODELS_DIR` | Speech models directory (default `~/Library/Application Support/com.kidandcat.minerva/models`) |
| `MINERVA_RELAY` | Relay URL for the phone remote |
| `MINERVA_NO_MIC` | Keep the Mac's microphone off (tests) |
| `MINERVA_NO_WEBHOOKS` | Don't start the webhook helper |
| `MINERVA_NO_TELEGRAM` | Don't poll Telegram |
| `MINERVA_WEBHOOKS_BIN` | Path to the `minerva-webhooks` helper |

## Privacy and security

Read this before you run it.

- **Minerva acts without confirmations.** Every tool (shell commands, files, mouse and keyboard)
  runs at once. Safety rules live in the system prompt: destructive or irreversible
  actions only when the request is unmistakable, otherwise it asks first. Speech recognition can
  mishear. Run it only on a machine and accounts where you accept that.
- **What leaves your Mac**: your transcribed words, tool results and screenshots go to the brain's
  provider (Anthropic through Claude Code, Google through Antigravity, or OpenAI through Codex), and
  to the next one when a fallback takes over. Audio itself stays local.
- **Local data**: conversation history, memories, skills, projects and the vault live in the data
  directory, protected by file permissions. The vault is encrypted with AES-256-GCM, but its key sits
  next to it; it keeps secrets out of prompts, history and logs, not away from someone with your
  account.
- **Phone link**: the pairing key is only shared through the QR code. Messages and audio are encrypted
  end to end (X25519 + ChaCha20-Poly1305 with forward secrecy); the relay sees who is connected, when,
  and frame sizes.
- **Webhooks**: each webhook URL contains its own random key, which is the secret. Their content is
  marked as third-party for the brain.
- **Telegram**: only your own chat is accepted; messages pass through Telegram's servers.

See [docs/design.md](docs/design.md) §3.5, §3.7, §3.9 and §3.10 for the details and the threat model.

## Contributing

Issues and pull requests are welcome. Please keep changes small and focused, run `flutter test` and
`go test ./...`, and update `docs/design.md` when behavior changes. Never commit models, tokens or
personal data.

## License

[MIT](LICENSE) © 2026 kidandcat. Speech models are downloaded from their own sources under their own
licenses (Parakeet: CC-BY-4.0; Supertonic 3: code MIT, weights OpenRAIL-M; Silero VAD: MIT).
