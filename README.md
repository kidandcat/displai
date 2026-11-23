# Minerva

A voice-first desktop assistant for macOS built with Flutter. You talk; it answers briefly and shows
the rest on screen. Claude Code (your own install and login) runs underneath as the brain, and the
app exposes the display to it through an embedded MCP server. Speech runs locally (sherpa-onnx).

The same app on Android is a remote: pair it with the QR from the desktop's phone button, and the
phone becomes the mic, speaker and display while everything is still processed on the desktop. Both
sides connect through a small relay (`relay/`). See [docs/design.md §3.7](docs/design.md#37-phone-remote).

Status: design phase. See [docs/design.md](docs/design.md).
