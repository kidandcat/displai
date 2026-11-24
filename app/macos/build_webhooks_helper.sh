#!/bin/zsh
# Xcode build phase: builds the minerva-webhooks helper (../relay/cmd/minerva-webhooks) as a
# universal binary into Minerva.app/Contents/MacOS, next to the app's executable, where
# lib/webhooks/webhooks.dart looks for it. Without Go the app still builds, just without webhooks.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:$PATH"
src="$PROJECT_DIR/../../relay"
dest="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/minerva-webhooks"
if ! command -v go >/dev/null; then
  echo "warning: Go not found; Minerva.app is built without webhooks (minerva-webhooks)."
  exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$src"
for arch in arm64 amd64; do
  GOOS=darwin GOARCH=$arch CGO_ENABLED=0 GOTOOLCHAIN=local \
    go build -trimpath -ldflags='-s -w' -o "$tmp/$arch" ./cmd/minerva-webhooks
done
lipo -create -output "$dest" "$tmp/arm64" "$tmp/amd64"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime "$dest"
