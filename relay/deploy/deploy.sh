#!/usr/bin/env bash
# Builds the relay and installs it on the VPS as a systemd service (first run also creates the
# user and the unit). Caddy and Gatus are configured once by hand: see Caddyfile.snippet.
# Usage: deploy/deploy.sh [ssh-host]   (default: vps2)
set -euo pipefail
cd "$(dirname "$0")/.."
host="${1:-vps2}"
go test ./...
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /tmp/minerva-relay .
scp -q /tmp/minerva-relay deploy/minerva-relay.service "$host":/tmp/
ssh "$host" 'set -e
  id minerva-relay >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin minerva-relay
  sudo install -d -m 755 /opt/minerva-relay
  sudo install -m 755 /tmp/minerva-relay /opt/minerva-relay/minerva-relay
  sudo install -m 644 /tmp/minerva-relay.service /etc/systemd/system/minerva-relay.service
  rm -f /tmp/minerva-relay /tmp/minerva-relay.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now minerva-relay
  sudo systemctl restart minerva-relay
  sleep 1
  systemctl is-active minerva-relay
  curl -fsS http://127.0.0.1:8094/health'
