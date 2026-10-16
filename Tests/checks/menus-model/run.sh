#!/bin/bash
# MenusModel (Sources/SillClient/MenusModel.swift, the Mac Client's Menus button, DCritelli/sill#8)
# over the shared iOSClient/MacMenuState.swift: the button's top level following the Host, menus
# opened by key and fetched once, items with shortcut text, disabled and checked marks, choices and
# their refusals, timeouts and the connection's end. Pure; under a few seconds.
#   Tests/checks/menus-model/run.sh             compile and run
#   Tests/checks/menus-model/run.sh --mutants   one-line mutants of MenusModel.swift; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
rm -f "$out/check"
"$here/build.sh" "$root" "$out/check"
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
