#!/bin/bash
# Builds Sill Client.app, the Mac Client (docs/adr/0001), from this SwiftPM package.
#
#   Scripts/make-client-app.sh          .build/Sill Client.app, signed with your Apple Development identity
#   Scripts/make-client-app.sh --open   …and launch it
#
# The same steps as Scripts/make-app.sh, without what only the Host needs: no Screen Recording or
# Accessibility to keep across rebuilds, no release path yet, and the generic icon. Local Network is
# the one grant it asks for (Bonjour), which macOS ties to the bundle ID and the signature.
set -euo pipefail
cd "$(dirname "$0")/.."

open_app=0
for arg in "$@"; do
    case "$arg" in
        --open) open_app=1 ;;
        *) echo "usage: $0 [--open]" >&2; exit 2 ;;
    esac
done

swift build -c release --product SillClient
bin="$(swift build -c release --show-bin-path)/SillClient"

app=".build/Sill Client.app"
stage="$(mktemp -d)/Sill Client.app"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp Packaging/ClientInfo.plist "$stage/Contents/Info.plist"
cp "$bin" "$stage/Contents/MacOS/Sill Client"

# As make-app.sh: SILL_SIGN_IDENTITY, else the first Apple Development identity by its SHA-1 hash,
# else ad hoc (macOS then asks for Local Network again after every rebuild).
identity="${SILL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $2; exit }' || true)}"
if [ -z "$identity" ]; then
    identity="-"
    echo "warning: no Apple Development identity in the keychain; signing ad hoc." >&2
fi
codesign --force --sign "$identity" --timestamp=none "$stage"
codesign --verify --strict "$stage"

rm -rf "$app"
mv "$stage" "$app"
echo "Built $app ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist"))"
if [ "$open_app" = 1 ]; then open "$app"; fi
