"""Each mutant of MenusModel.swift must fail the menus-model check (main.swift).
usage: mutants.py ROOT"""
import os, subprocess, sys
SP = os.path.dirname(os.path.abspath(__file__))
ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(os.path.join(SP, "..", "..", ".."))
OUT = os.path.join(ROOT, ".build", "checks", "menus-model")
os.makedirs(OUT, exist_ok=True)
SRC = os.path.join(ROOT, "Sources/SillClient/MenusModel.swift")
orig = open(SRC).read()
MUTANTS = {
    "M1 disabled looks enabled": [("enabled: row.enabled && row.kind != .note", "enabled: row.kind != .note")],
    "M3 mark ignored": [("let check: Item.Check = row.mark == .on ? .on : (row.mark == .mixed ? .mixed : .off)", "let check: Item.Check = .off")],
    "M4 mixed as on": [("row.mark == .on ? .on : (row.mark == .mixed ? .mixed : .off)", "row.mark == .off ? .off : .on")],
    "M5 shortcut dropped": [("shortcut: row.key,", "shortcut: nil,")],
    "M6 submenu as item": [("let kind: Item.Kind = row.kind == .submenu ? .submenu : (row.kind == .note ? .note : .item)", "let kind: Item.Kind = row.kind == .note ? .note : .item")],
    "M7 sections flattened": [("case .sections(let sections, _): return sections.map { $0.map(item) }", "case .sections(let sections, _): return [sections.flatMap { $0.map(item) }]")],
    "M8 key reused": [("let key = nextKey; nextKey += 1", "let key = nextKey")],
    "M9 token reused": [("let token = nextToken; nextToken += 1", "let token = nextToken")],
    "M10 choice token reused": [("        nextToken += 1\n        return press", "        return press")],
    "M11 choice ignores the state's refusal": [("guard let press = state.press(item.row, token: token) else { return nil }", "state.menus.isEmpty ? () : (); let press = state.press(item.row, token: token) ?? .send(PressMenuItem(version: item.row.version, id: item.row.id, title: item.row.title, token: token))")],
    "M12 timeout never": [("Self.settled(state.expire(now: now, timeout: timeout, mac: mac))", "[]")],
    "M13 reset keeps menus": [("Self.settled(state.reset())", "Self.settled(state.connectionReplaced())")],
    "M14 words as enabled item": [("case .message(let text): return [[item(.note(text))]]", "case .message(let text): return [[Item(kind: .item, title: text, shortcut: nil, enabled: true, check: .off, row: .note(text))]]")],
    "M15 top level unordered": [("state.menus.map(Self.item)", "state.menus.reversed().map(Self.item)")],
    "M16 receive hides topChanged": [("topChanged: r.topChanged", "topChanged: false")],
    "M17 receive drops settled": [("settled: Self.settled(r.done)", "settled: []")],
    "M18 refusal dropped": [("refusal: r.refusal)", "refusal: nil)")],
    "M19 no id asks anyway": [('guard let id = row.id else { return Opened(key: key, send: nil, now: Self.items(.message(MacMenuState.notConnected))) }', 'let id = row.id ?? "1"')],
}
caught = 0
for name, edits in MUTANTS.items():
    src = orig
    for old, new in edits:
        n = src.count(old)
        if n != 1:
            print(f"{name}: NOT APPLIED (pattern found {n} times)"); src = None; break
        src = src.replace(old, new)
    if src is None: continue
    path = os.path.join(OUT, "MenusModel.swift")
    open(path, "w").write(src)
    b = subprocess.run([os.path.join(SP, "build.sh"), ROOT, os.path.join(OUT, "mutant"), path], capture_output=True, text=True)
    if b.returncode != 0 or b.stdout.strip() or not os.path.exists(os.path.join(OUT, "mutant")):
        print(f"{name}: DOES NOT COMPILE\n{b.stdout[:600]}"); continue
    try:
        r = subprocess.run([os.path.join(OUT, "mutant")], capture_output=True, text=True, timeout=60)
        failed = [l[5:] for l in r.stdout.splitlines() if l.startswith("FAIL")]
        ok = r.returncode != 0
        detail = f"{len(failed)} failing, e.g. {failed[:2]}" if failed else f"exit status {r.returncode}"
    except subprocess.TimeoutExpired:
        ok, detail = True, "timed out (60 s)"
    os.remove(os.path.join(OUT, "mutant"))
    caught += ok
    print(f"{'caught' if ok else 'MISSED'} {name}: {detail}")
print(f"{caught} of {len(MUTANTS)} mutants caught")
sys.exit(0 if caught == len(MUTANTS) else 1)
