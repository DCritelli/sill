#!/bin/bash
# usage: build.sh WT OUT [MenusModel.swift override]
# Compiles the Mac Client's MenusModel.swift and the shared MacMenuState.swift with StreamProtocol's
# sources as one module (their `import StreamProtocol` stripped), as the menu-state check does.
WT=$1; OUT=$2; T=$(mktemp -d)
cp "$WT"/Sources/StreamProtocol/*.swift "$T"/
sed '/^import StreamProtocol$/d' "$WT/iOSClient/MacMenuState.swift" > "$T/MacMenuState.swift"
cp "${3:-$WT/Sources/SillClient/MenusModel.swift}" "$T/MenusModel.swift"
cp "$(dirname "$0")/main.swift" "$T/main.swift"
swiftc -O "$T"/*.swift -o "$OUT" 2>&1 | grep -E "error"; rm -rf "$T"
