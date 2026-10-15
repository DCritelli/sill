"""Each mutant of ClientSession.swift must fail the client-session check (main.swift).
usage: mutants.py"""
import glob, os, subprocess, sys
SP = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(SP, "..", "..", ".."))   # the repository
OUT = os.path.join(ROOT, ".build", "checks", "client-session")   # the mutants' sources and binaries
os.makedirs(OUT, exist_ok=True)
SRC = os.path.join(ROOT, "Sources/SillClient/ClientSession.swift")
orig = open(SRC).read()
MUTANTS = {
    "C1 no hello": [("            send(.hello, Wire.encode(hello))\n", "")],
    "C2 the hello after the start": [
        ("            send(.hello, Wire.encode(hello))\n            connection.start(queue: queue)\n",
         "            connection.start(queue: queue)\n            queue.asyncAfter(deadline: .now() + 0.3) { self.send(.hello, Wire.encode(self.hello)) }\n")],
    "C3 the last Window, not the first": [("list.windows.first.map", "list.windows.last.map")],
    "C4 no Desktop for an empty list": [("list.windows.first.map { .window($0.id) } ?? .desktop", "list.windows.first.map { .window($0.id) } ?? .none")],
    "C5 the Desktop pick ignored": [("        case .desktop: source = .desktop\n", "        case .desktop: source = list.windows.first.map { .window($0.id) } ?? .desktop\n")],
    "C6 every list picks": [("            if picked == nil { choose(from: list) }", "            choose(from: list)")],
    "C7 no Viewport": [("        send(.viewport, Wire.encode(viewport))\n", "")],
    "C8 the Viewport before the pick": [
        ("        send(.selectSource, Wire.encode(source))\n        send(.viewport, Wire.encode(viewport))\n",
         "        send(.viewport, Wire.encode(viewport))\n        send(.selectSource, Wire.encode(source))\n")],
    "C9 the keyframe flag dropped": [("            onFrame?(payload, header.isKeyframe)", "            onFrame?(payload, true)")],
    "C10 no parameter sets": [("            if let sets = ParameterSets(encoded: payload) { onParameterSets?(sets) }", "            break")],
    "C11 no pings": [("                    startPinging()\n", "")],
    "C12 the end not reported": [("        connection.cancel()\n        onEnd?(why)\n", "        connection.cancel()\n")],
    "C13 stop() reports the end": [
        ("            guard running else { return }\n            running = false\n            pingTimer?.cancel()\n            connection.cancel()\n        }\n",
         "            guard running else { return }\n            end(\"stopped\")\n        }\n")],
    "C15 the list not handed on": [("            onWindowList?(list)\n", "")],
    "C16 no cursor shape handed on": [("            onCursorShape?(payload)\n", "            break\n")],
    "C17 only the first input sent": [("            for event in events { send(.input, Wire.encode(event)) }", "            send(.input, Wire.encode(events[0]))")],
    "C18 input sent in reverse": [("            for event in events { send(.input, Wire.encode(event)) }", "            for event in events.reversed() { send(.input, Wire.encode(event)) }")],
    # Not a mutant here: dropping `end`'s own `guard running`. The session cancels its connection as
    # it ends, so no second end can arrive (the reader stops on `running`, a cancelled connection
    # reports .cancelled, which is ignored); the guard stays for a stack that does.
}
caught = 0
for name, edits in MUTANTS.items():
    src = orig
    for old, new in edits:
        n = src.count(old)
        if n != 1:
            print(f"{name}: NOT APPLIED (pattern found {n} times)")
            src = None
            break
        src = src.replace(old, new)
    if src is None: continue
    path = os.path.join(OUT, "ClientSession.swift")
    open(path, "w").write(src)
    sources = [path, os.path.join(ROOT, "iOSClient/MessageReader.swift")] + sorted(glob.glob(os.path.join(ROOT, "Sources/StreamProtocol/*.swift")))
    b = subprocess.run(["swiftc", "-O"] + sources + [os.path.join(SP, "main.swift"), "-o", os.path.join(OUT, "mutant")],
                       capture_output=True, text=True)
    if b.returncode != 0:
        print(f"{name}: DOES NOT COMPILE\n{b.stderr[:600]}"); continue
    try:
        r = subprocess.run([os.path.join(OUT, "mutant")], capture_output=True, text=True, timeout=120)
        failed = [l[5:] for l in r.stdout.splitlines() if l.startswith("FAIL")]
        ok = r.returncode != 0
        detail = f"{len(failed)} failing, e.g. {failed[:2]}" if failed else f"exit status {r.returncode}"
    except subprocess.TimeoutExpired:
        ok, detail = True, "timed out (120 s)"
    caught += ok
    print(f"{'caught' if ok else 'MISSED'} {name}: {detail}")
print(f"{caught} of {len(MUTANTS)} mutants caught")
sys.exit(0 if caught == len(MUTANTS) else 1)
