#!/bin/bash
# ClientSession, ClientPairing and ClientConnection (Sources/SillClient, the Mac Client's session, pairing
# and reconnect, DCritelli/sill#10, #2, #9) with iOSClient/MessageReader.swift, iOSClient/SavedMacs.swift, iOSClient/GoodbyePolicy.swift and StreamProtocol,
# against a stand-in Host on loopback (plain, and a TLS door with Require pairing on). About 15 s.
#   Tests/checks/client-session/run.sh [CASE...]   compile, then run every case (or the ones named)
#   Tests/checks/client-session/run.sh --mutants   one-line mutants of ClientSession.swift and ClientPairing.swift; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py"; exit; fi
# SavedMacs.swift imports StreamProtocol, which is one module with this check: the import goes.
sed '/^import StreamProtocol$/d' iOSClient/SavedMacs.swift > "$out/SavedMacs.swift"
sed '/^import StreamProtocol$/d' iOSClient/GoodbyePolicy.swift > "$out/GoodbyePolicy.swift"
swiftc -O Sources/SillClient/ClientSession.swift Sources/SillClient/ClientPairing.swift Sources/SillClient/ClientConnection.swift \
    iOSClient/MessageReader.swift "$out/SavedMacs.swift" "$out/GoodbyePolicy.swift" Sources/StreamProtocol/*.swift \
    "$here/main.swift" -o "$out/check"
"$out/check" "$@"
