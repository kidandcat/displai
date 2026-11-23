#!/usr/bin/env bash
# Builds the relay and installs it on the VPS as a systemd service (first run also creates the
# user and the unit). Caddy and Gatus are configured once by hand: see Caddyfile.snippet.
# Usage: deploy/deploy.sh [ssh-host]   (default: vps2)
set -euo pipefail
cd "$(dirname "$0")/.."
host="${1:-vps2}"
go test ./...
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /tmp/displai-relay .
scp -q /tmp/displai-relay deploy/displai-relay.service "$host":/tmp/
ssh "$host" 'set -e
  id displai-relay >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin displai-relay
  sudo install -d -m 755 /opt/displai-relay
  sudo install -m 755 /tmp/displai-relay /opt/displai-relay/displai-relay
  sudo install -m 644 /tmp/displai-relay.service /etc/systemd/system/displai-relay.service
  rm -f /tmp/displai-relay /tmp/displai-relay.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now displai-relay
  sudo systemctl restart displai-relay
  sleep 1
  systemctl is-active displai-relay
  curl -fsS http://127.0.0.1:8094/health'
