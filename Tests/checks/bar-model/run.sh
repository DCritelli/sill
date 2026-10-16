#!/bin/bash
# BarModel, BarVisibility and FrameMemory (Sources/SillClient/BarModel.swift, the Mac Client's Bar,
# DCritelli/sill#7) with StreamProtocol's Switcher.swift. Pure: no network, no AppKit. Under a second.
#   Tests/checks/bar-model/run.sh             compile and run
#   Tests/checks/bar-model/run.sh --mutants   one-line mutants of BarModel.swift; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py"; exit; fi
swiftc -O Sources/SillClient/BarModel.swift Sources/StreamProtocol/Switcher.swift Sources/StreamProtocol/StreamMessage.swift "$here/main.swift" -o "$out/check"
"$out/check"
