#!/bin/bash
# InputTranslator (Sources/SillClient/InputTranslator.swift, the Mac Client's input translator,
# DCritelli/sill#3) with StreamProtocol's Input.swift, Viewport.swift and StreamMessage.swift. Pure: no network, no AppKit. Under a second.
#   Tests/checks/input-translator/run.sh             compile and run
#   Tests/checks/input-translator/run.sh --mutants   one-line mutants of InputTranslator.swift; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py"; exit; fi
swiftc -O Sources/SillClient/InputTranslator.swift Sources/StreamProtocol/Input.swift \
    Sources/StreamProtocol/Viewport.swift Sources/StreamProtocol/StreamMessage.swift "$here/main.swift" -o "$out/check"
"$out/check"
