"""Each mutant of InputTranslator.swift must fail the input-translator check (main.swift).
usage: mutants.py"""
import os, subprocess, sys
SP = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(SP, "..", "..", ".."))   # the repository
OUT = os.path.join(ROOT, ".build", "checks", "input-translator")   # the mutants' sources and binaries
os.makedirs(OUT, exist_ok=True)
SRC = os.path.join(ROOT, "Sources/SillClient/InputTranslator.swift")
orig = open(SRC).read()
MUTANTS = {
    "T1 stretched, not fitted": [("min(contentSize.width / frame.width, contentSize.height / frame.height)",
                                  "max(contentSize.width / frame.width, contentSize.height / frame.height)")],
    "T2 not centred across": [("x: (contentSize.width - width) / 2,", "x: 0,")],
    "T3 not centred down": [("y: (contentSize.height - height) / 2,", "y: 0,")],
    "T4 positions from the view, not the picture": [("Double((point.x - rect.minX) / rect.width)", "Double(point.x / rect.width)")],
    "T5 y from the bottom": [("y = Double((point.y - rect.minY) / rect.height)", "y = 1 - Double((point.y - rect.minY) / rect.height)")],
    "T6 moves from the bars sent": [("        guard (0...1).contains(x), (0...1).contains(y) else { return nil }\n", "")],
    "T7 only x checked": [("guard (0...1).contains(x), (0...1).contains(y) else", "guard (0...1).contains(x) else")],
    "T8 a drag not held at the edge": [("guard let p = normalized(point, clamped: !held.isEmpty)", "guard let p = normalized(point)")],
    "T9 every move clamped": [("normalized(point, clamped: !held.isEmpty)", "normalized(point, clamped: true)")],
    "T10 the up not held at the edge": [("held.remove(button) != nil, let p = normalized(point, clamped: true)",
                                         "held.remove(button) != nil, let p = normalized(point)")],
    "T11 an up the Host never had a down for": [("guard held.remove(button) != nil, let p", "guard (held.remove(button) != nil || true), let p")],
    "T12 a down on a bar sent": [("        guard let p = normalized(point) else { return [] }\n        held.insert(button)\n",
                                  "        held.insert(button)\n        guard let p = normalized(point, clamped: true) else { return [] }\n")],
    "T13 the button not remembered": [("        held.insert(button)\n", "")],
    "T14 a right down sent as left": [("button == .left ? .leftDown : .rightDown", ".leftDown")],
    "T15 a right up sent as left": [("button == .left ? .leftUp : .rightUp", ".leftUp")],
    "T16 the drag ends with the first up": [("held.remove(button) != nil", "held.removeAll() != ()")],
    "T17 clamped low only": [("(min(max(x, 0), 1), min(max(y, 0), 1))", "(max(x, 0), max(y, 0))")],
    "T18 a picture with no frame": [("guard let frame = frameSize, frame.width > 0, frame.height > 0,",
                                     "guard let frame = frameSize,")],
    "S1 dx negated": [("dx: Double(dx / rect.width)", "dx: -Double(dx / rect.width)")],
    "S2 dy negated (unnatural scrolling)": [("dy: Double(dy / rect.height)", "dy: -Double(dy / rect.height)")],
    "S3 dx a fraction of the height": [("Double(dx / rect.width)", "Double(dx / rect.height)")],
    "S4 dy a fraction of the view, not the picture": [("Double(dy / rect.height)", "Double(dy / contentSize.height)")],
    "S5 axes swapped": [("dx: Double(dx / rect.width), dy: Double(dy / rect.height)", "dx: Double(dy / rect.height), dy: Double(dx / rect.width)")],
    "S6 zero deltas sent": [("guard let rect = pictureRect, dx != 0 || dy != 0 else", "guard let rect = pictureRect else")],
    "S7 a wheel with a gesture": [("            return delta(at: p, dx: dx, dy: dy)\n        case (.began, _):",
                                   "            return [.scrollGesture(.began, x: p.x, y: p.y)] + delta(at: p, dx: dx, dy: dy)\n        case (.began, _):")],
    "S8 a wheel over the bars": [("        case (.none, .none):   // a wheel: plain scrolls over the picture\n            guard let p = normalized(point) else",
                                  "        case (.none, .none):   // a wheel: plain scrolls over the picture\n            guard let p = normalized(point, clamped: true) else")],
    "S9 no began": [("return out + [.scrollGesture(.began, x: p.x, y: p.y)] + delta", "return out + delta")],
    "S10 began without its delta": [("return out + [.scrollGesture(.began, x: p.x, y: p.y)] + delta(at: p, dx: dx, dy: dy)",
                                     "return out + [.scrollGesture(.began, x: p.x, y: p.y)]")],
    "S11 a gesture begun over a bar": [("guard let p = normalized(point) else { scrolling = .idle; return out }",
                                        "guard let p = normalized(point, clamped: true) else { scrolling = .idle; return out }")],
    "S12 momentum not ended by new fingers": [("            if scrolling == .momentum, let p = normalized(point, clamped: true) {\n                out.append(.scrollGesture(.momentumEnded, x: p.x, y: p.y))\n            }\n", "")],
    "S13 cancelled not ended": [("case (.ended, _), (.cancelled, _):", "case (.ended, _):\n            guard scrolling == .gesture, let p = normalized(point, clamped: true) else { return [] }\n            scrolling = .ended\n            return [.scrollGesture(.ended, x: p.x, y: p.y)]\n        case (.cancelled, _):\n            return []\n        case (.none, .ended) where false:")],
    "S14 ended sent as momentumEnded": [("            scrolling = .ended\n            return [.scrollGesture(.ended, x: p.x, y: p.y)]",
                                          "            scrolling = .ended\n            return [.scrollGesture(.momentumEnded, x: p.x, y: p.y)]")],
    "S15 no momentumBegan": [("return [.scrollGesture(.momentumBegan, x: p.x, y: p.y)] + delta", "return delta")],
    "S16 no momentumEnded": [("            scrolling = .idle\n            return [.scrollGesture(.momentumEnded, x: p.x, y: p.y)]", "            scrolling = .idle\n            return []")],
    "S17 momentum after a foreign gesture": [("guard scrolling == .ended, let p", "guard scrolling != .momentum, let p")],
    "S18 a foreign gesture's deltas sent": [("        case (.changed, _):\n            guard scrolling == .gesture,", "        case (.changed, _):\n            guard true,")],
    "S19 a gesture's pointer not held at the edge": [("        case (.changed, _):\n            guard scrolling == .gesture, let p = normalized(point, clamped: true)",
                                                     "        case (.changed, _):\n            guard scrolling == .gesture, let p = normalized(point)")],
    "S20 momentum deltas dropped": [("        case (.none, .changed):\n            guard scrolling == .momentum, let p = normalized(point, clamped: true) else { return [] }\n            return delta(at: p, dx: dx, dy: dy)",
                                     "        case (.none, .changed):\n            return []")],
    "S21 momentum not closed": [("            scrolling = .idle\n            return [.scrollGesture(.momentumEnded", "            return [.scrollGesture(.momentumEnded")],
    "S22 resting fingers begin a gesture": [("        case (.mayBegin, _), (.stationary, _):\n            return []",
                                             "        case (.mayBegin, _), (.stationary, _):\n            guard let p = normalized(point) else { return [] }\n            return [.scrollGesture(.began, x: p.x, y: p.y)]")],
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
    path = os.path.join(OUT, "InputTranslator.swift")
    open(path, "w").write(src)
    b = subprocess.run(["swiftc", "-O", path, os.path.join(ROOT, "Sources/StreamProtocol/Input.swift"),
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
