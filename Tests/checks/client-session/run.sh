#!/bin/bash
# ClientSession (Sources/SillClient/ClientSession.swift, the Mac Client's session, DCritelli/sill#10)
# with iOSClient/MessageReader.swift and StreamProtocol, against a stand-in Host on loopback. About 5 s.
#   Tests/checks/client-session/run.sh [CASE...]   compile, then run every case (or the ones named)
#   Tests/checks/client-session/run.sh --mutants   one-line mutants of ClientSession.swift; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py"; exit; fi
swiftc -O Sources/SillClient/ClientSession.swift iOSClient/MessageReader.swift Sources/StreamProtocol/*.swift \
    "$here/main.swift" -o "$out/check"
"$out/check" "$@"
