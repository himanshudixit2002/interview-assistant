#!/bin/bash
# Assembles "Interview Assistant.app" from the SwiftPM build and signs it ad hoc. Xcode or Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
APP="Interview Assistant.app"
CONTENTS="$APP/Contents"
echo "==> Building (release)"
swift build -c release --product InterviewAssistant 2>&1 | grep -vE "ld: warning: search path|^\s*$" || true
BINARY=".build/release/InterviewAssistant"
[ -f "$BINARY" ] || { echo "!! build produced no binary"; exit 1; }
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/InterviewAssistant"
cp Info.plist "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
echo "==> Signing (ad hoc)"
codesign --force --sign - --timestamp=none --entitlements entitlements.plist "$APP" 2>/dev/null || codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/   /'
echo "==> Done: $(pwd)/$APP"
