# Minerva

A voice-first desktop assistant for macOS built with Flutter. You talk; it answers briefly and shows
the rest on screen. Claude Code (your own install and login) runs underneath as the brain, and the
app exposes the display to it through an embedded MCP server. Speech runs locally (sherpa-onnx).

The same app on Android is a remote: pair it with the QR from the desktop's phone button, and the
phone becomes the mic, speaker and display while everything is still processed on the desktop. Both
sides connect through a small relay (`relay/`), and everything between them is end-to-end encrypted
with keys derived from the QR code, so the relay only forwards ciphertext. See
[docs/design.md §3.7](docs/design.md#37-phone-remote).

To see what the relay sees, run your own with `cd relay && go run . -addr 0.0.0.0:8094 -tap`, point the desktop at
it with `MINERVA_RELAY=ws://<host>:8094`, and pair the phone: apart from two handshake frames with
ephemeral public keys, every frame it logs is ciphertext.

Status: design phase. See [docs/design.md](docs/design.md).
