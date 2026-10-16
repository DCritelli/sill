"""Each mutant of BarModel.swift must fail the bar-model check (main.swift).
usage: mutants.py"""
import os, subprocess, sys
SP = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(SP, "..", "..", ".."))
OUT = os.path.join(ROOT, ".build", "checks", "bar-model")
os.makedirs(OUT, exist_ok=True)
SRC = os.path.join(ROOT, "Sources/SillClient/BarModel.swift")
orig = open(SRC).read()
MUTANTS = {
    "B1 a new Window becomes the Source": [("        active = list.active\n", "        if case .window = list.active, let new = list.windows.last, !knownBefore.contains(new.id), !knownBefore.isEmpty { active = .window(new.id) } else { active = list.active }\n")],
    "B2 Host order lost": [("        windows = list.windows\n", "        windows = list.windows.sorted { $0.id > $1.id }\n")],
    "B3 thumbnails never dropped": [("thumbnails = thumbnails.filter { listed.contains($0.key) || !knownBefore.contains($0.key) }", "")],
    "B4 early thumbnails dropped": [("listed.contains($0.key) || !knownBefore.contains($0.key)", "listed.contains($0.key)")],
    "B5 icon by Window, not app": [("icon: icons[$0.bundleID]", "icon: icons.values.first")],
    "B6 any Window selectable": [("windows.contains { $0.id == windowID } ? .window(windowID) : nil", ".window(windowID)")],
    "B7 any Window commandable": [("windows.contains { $0.id == windowID } ? WindowCommand(id: windowID, action: action) : nil", "WindowCommand(id: windowID, action: action)")],
    "B8 command on the wrong action": [("WindowCommand(id: windowID, action: action)", "WindowCommand(id: windowID, action: .close)")],
    "B9 Desktop selects nothing": [("var selectDesktop: StreamSource { .desktop }", "var selectDesktop: StreamSource { .none }")],
    "B10 title without the app": [('return "\\(w.title) \\u{2014} \\(w.appName)"', "return w.title")],
    "B11 empty title not the app": [("if w.title.isEmpty || w.title == w.appName { return w.appName }", "if w.title == w.appName { return w.appName }")],
    "B12 Desktop title without Host": [('return "Desktop \\u{2014} \\(macName)"', 'return "Desktop"')],
    "B13 hidden pointer reveals outside full screen": [("!userHidden && (!fullScreen || pointerAtTop)", "!fullScreen || pointerAtTop")],
    "B14 full screen not hidden": [("!userHidden && (!fullScreen || pointerAtTop)", "!userHidden")],
    "B15 user hide ignored at the top": [("!userHidden && (!fullScreen || pointerAtTop)", "(!userHidden || (fullScreen && pointerAtTop)) && (!fullScreen || pointerAtTop)")],
    "B16 menu title never changes": [('userHidden ? "Show Bar" : "Hide Bar"', '"Hide Bar"')],
    "B17 edge band too wide": [("static let edgeBand: CGFloat = 4", "static let edgeBand: CGFloat = 40")],
    "B18 revealed Bar not kept": [("y <= barHeight", "y <= edgeBand")],
    "B19 frames shared across Hosts": [("frames[key] = [", "frames[\"all\"] = [")],
    "B20 empty frame remembered": [("guard frame.width > 0, frame.height > 0 else { return }", "")],
    "B21 key by name for saved Hosts": [('macID.map { "mac:\\($0)" } ?? "name:\\(name)"', '"name:\\(name)"')],
    "B22 width and height swapped": [("CGRect(x: f[0], y: f[1], width: f[2], height: f[3])", "CGRect(x: f[0], y: f[1], width: f[3], height: f[2])")],
    "B23 no Host name before a list": [('guard !macName.isEmpty else { return "Sill Client" }', 'guard !macName.isEmpty else { return "" }')],
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
    path = os.path.join(OUT, "BarModel.swift")
    open(path, "w").write(src)
    b = subprocess.run(["swiftc", "-O", path, os.path.join(ROOT, "Sources/StreamProtocol/Switcher.swift"),
                        os.path.join(ROOT, "Sources/StreamProtocol/StreamMessage.swift"),
                        os.path.join(SP, "main.swift"), "-o", os.path.join(OUT, "mutant")], capture_output=True, text=True)
    if b.returncode != 0:
        print(f"{name}: DOES NOT COMPILE\n{b.stderr[:600]}"); continue
    try:
        r = subprocess.run([os.path.join(OUT, "mutant")], capture_output=True, text=True, timeout=60)
        failed = [l[5:] for l in r.stdout.splitlines() if l.startswith("FAIL")]
        ok = r.returncode != 0
        detail = f"{len(failed)} failing, e.g. {failed[:2]}" if failed else f"exit status {r.returncode}"
    except subprocess.TimeoutExpired:
        ok, detail = True, "timed out (60 s)"
    caught += ok
    print(f"{'caught' if ok else 'MISSED'} {name}: {detail}")
print(f"{caught} of {len(MUTANTS)} mutants caught")
sys.exit(0 if caught == len(MUTANTS) else 1)
