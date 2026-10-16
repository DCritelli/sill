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
    "T12 a down on a bar sent": [("        guard !bringsWindowForward, let p = normalized(point) else { return [] }\n        held.insert(button)\n",
                                  "        held.insert(button)\n        guard let p = normalized(point, clamped: true) else { return [] }\n")],
    "T13 the button not remembered": [("        held.insert(button)\n", "")],
    "T14 a right down sent as left": [("button == .left ? .leftDown : .rightDown", ".leftDown")],
    "T15 a right up sent as left": [("return [.pointer(button == .left ? .leftUp : .rightUp", "return [.pointer(.leftUp")],
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
    "K1 a letter mapped wrong (B as C)": [("0x00: 0x04, 0x0B: 0x05,", "0x00: 0x04, 0x0B: 0x06,")],
    "K2 F12 dropped": [("0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45,", "0x65: 0x42, 0x6D: 0x43, 0x67: 0x44,")],
    "K3 an arrow mapped wrong (Up as Down)": [("        0x7E: 0x52,\n", "        0x7E: 0x51,\n")],
    "K4 an unmapped key sent as its code": [("guard let usage = Self.hidUsages[keyCode] else { return [] }\n        if !keysDown",
                                              "let usage = Self.hidUsages[keyCode] ?? keyCode\n        if !keysDown")],
    "K5 the keypad sent as keys": [("        if let text = Self.keypadText[keyCode] { return [.text(text)] }\n", "")],
    "K6 keypad Enter typed as nothing": [('0x51: "=", 0x4C: "\\n",', '0x51: "=",')],
    "K7 a keypad digit typed wrong": [('0x5B: "8", 0x5C: "9",', '0x5B: "8", 0x5C: "8",')],
    "K8 AppKit's bits sent": [("modifiers: flags & Self.hostFlags)", "modifiers: flags)")],
    "K9 caps lock's bit not sent": [("static let hostFlags: UInt64 = 0x1F_0000", "static let hostFlags: UInt64 = 0x1E_0000")],
    "K10 a down carries only held keys": [("modifiers: flags & Self.hostFlags)", "modifiers: heldFlags)")],
    "K11 an up carries nothing": [("        keysDown.remove(at: i)\n        return [.key(hidUsage: usage, down: false, modifiers: heldFlags)]",
                                   "        keysDown.remove(at: i)\n        return [.key(hidUsage: usage, down: false, modifiers: 0)]")],
    "K12 an up the Host never had": [("guard let usage = Self.hidUsages[keyCode], let i = keysDown.firstIndex(of: usage) else { return [] }\n        keysDown.remove(at: i)",
                                      "guard let usage = Self.hidUsages[keyCode] else { return [] }\n        if let i = keysDown.firstIndex(of: usage) { keysDown.remove(at: i) }")],
    "K13 a key not remembered": [("        if !keysDown.contains(usage) { keysDown.append(usage) }\n", "")],
    "K14 repeats remembered twice": [("        if !keysDown.contains(usage) { keysDown.append(usage) }\n", "        keysDown.append(usage)\n")],
    "M1 left and right shift one key": [("0x3C: (0xE5, 0x02_0000, 0x0004)", "0x3C: (0xE1, 0x02_0000, 0x0004)")],
    "M2 right command's device bit wrong": [("0x36: (0xE7, 0x10_0000, 0x0010)", "0x36: (0xE7, 0x10_0000, 0x0008)")],
    "M3 device bits ignored": [("let isDown = flags & Self.deviceBits != 0 ? flags & modifier.device != 0 : flags & modifier.flag != 0",
                                "let isDown = flags & modifier.flag != 0")],
    "M4 no fallback without device bits": [("let isDown = flags & Self.deviceBits != 0 ? flags & modifier.device != 0 : flags & modifier.flag != 0",
                                            "let isDown = flags & modifier.device != 0")],
    "M5 right control's device bit not counted": [("static let deviceBits: UInt64 = 0x207F", "static let deviceBits: UInt64 = 0x007F")],
    "M6 a modifier down sent twice": [("            guard !modifiersDown.contains(modifier.usage) else { return [] }\n", "")],
    "M7 a modifier up the Host never had": [("            guard let i = modifiersDown.firstIndex(of: modifier.usage) else { return [] }\n            modifiersDown.remove(at: i)",
                                             "            if let i = modifiersDown.firstIndex(of: modifier.usage) { modifiersDown.remove(at: i) }")],
    "M8 a modifier's flags before it moved": [("        return [.key(hidUsage: modifier.usage, down: isDown, modifiers: heldFlags)]",
                                               "        return [.key(hidUsage: modifier.usage, down: isDown, modifiers: flags & Self.hostFlags & ~modifier.flag)]")],
    "M9 control's flag as shift": [("0x3B: (0xE0, 0x04_0000, 0x0001)", "0x3B: (0xE0, 0x02_0000, 0x0001)")],
    "F1 buttons not released on focus loss": [("        for button in [Button.left, .right] where held.contains(button) {", "        for button in [Button]() where held.contains(button) {")],
    "F2 the right button kept": [("for button in [Button.left, .right] where", "for button in [Button.left] where")],
    "F3 a released button still held": [("            held.remove(button)\n            if let point = lastPoint", "            if let point = lastPoint")],
    "F4 released at the middle, not where it was": [("            if let point = lastPoint, let p = normalized(point, clamped: true) {",
                                                      "            if let p = normalized(CGPoint(x: contentSize.width / 2, y: contentSize.height / 2), clamped: true) {")],
    "F5 keys not released on focus loss": [("        while let usage = keysDown.popLast() {\n            out.append", "        while let usage = keysDown.popLast(), false {\n            out.append")],
    "F6 modifiers not released on focus loss": [("        while let usage = modifiersDown.popLast() {\n            out.append", "        while let usage = modifiersDown.popLast(), false {\n            out.append")],
    "F7 modifiers released before the keys": [("        while let usage = keysDown.popLast() {\n            out.append(.key(hidUsage: usage, down: false, modifiers: heldFlags))\n        }\n        while let usage = modifiersDown.popLast() {\n            out.append(.key(hidUsage: usage, down: false, modifiers: heldFlags))\n        }",
                                                "        while let usage = modifiersDown.popLast() {\n            out.append(.key(hidUsage: usage, down: false, modifiers: heldFlags))\n        }\n        while let usage = keysDown.popLast() {\n            out.append(.key(hidUsage: usage, down: false, modifiers: heldFlags))\n        }")],
    "F8 keys released first pressed first": [("while let usage = keysDown.popLast()", "while let usage = keysDown.first.map({ keysDown.removeFirst(); return $0 })")],
    "F10 focus loss lets the right button go as left": [("out.append(.pointer(button == .left ? .leftUp : .rightUp", "out.append(.pointer(.leftUp")],
    "F9 the first click sent": [("guard !bringsWindowForward, let p = normalized(point) else", "guard let p = normalized(point) else")],
    "V1 a Window's scale left out": [("scale: sourceKind == .window ? 1 : nil, fps: fps)", "scale: nil, fps: fps)")],
    "V2 the Desktop sent a scale": [("scale: sourceKind == .window ? 1 : nil, fps: fps)", "scale: 1, fps: fps)")],
    "V3 the Desktop's resize sent": [("return sourceKind == .window && (current.width", "return (current.width")],
    "V4 no throttle": [("if lastSent == nil || now - lastSentAt >= Self.resizeInterval { return emit(now) }", "return emit(now)")],
    "V5 never sent at once": [("if lastSent == nil || now - lastSentAt >= Self.resizeInterval { return emit(now) }", "if lastSent == nil { return emit(now) }")],
    "V6 the held size lost": [("        held = true\n        return nil\n    }\n\n    /// The deadline", "        return nil\n    }\n\n    /// The deadline")],
    "V7 tick before its deadline": [("guard held, now - lastSentAt >= Self.resizeInterval else { return nil }", "guard held else { return nil }")],
    "V8 no final send": [("    mutating func resizeEnded(now: TimeInterval) -> Viewport? {\n        differs ? emit(now)", "    mutating func resizeEnded(now: TimeInterval) -> Viewport? {\n        false ? emit(now)")],
    "V9 the same size sent again": [("        guard let last = lastSent else { return true }\n", "        guard let last = lastSent, false else { return true }\n")],
    "V11 fps not capped by the Host": [("min(displayMaxFPS, hostMaxFPS ?? displayMaxFPS)", "displayMaxFPS")],
    "V12 fps capped the wrong way": [("min(displayMaxFPS, hostMaxFPS ?? displayMaxFPS)", "max(displayMaxFPS, hostMaxFPS ?? displayMaxFPS)")],
    "V13 a display change ignored": [("        displayMaxFPS = maxFPS\n", "")],
    "V14 a display change not sent": [("return fps == before ? nil : emit(now)\n    }\n\n    /// The Host's", "return nil\n    }\n\n    /// The Host's")],
    "V15 a 0 Hz display taken": [("guard maxFPS > 0 else { return nil }\n", "")],
    "V16 a new session remembers": [("        lastSent = nil\n        held = false\n    }\n\n    /// The stream view", "        held = false\n    }\n\n    /// The stream view")],
    "V17 a source change not sent": [("        sourceKind = kind\n        return emit(now)", "        sourceKind = kind\n        return nil")],
    "V18 an empty size sent": [("guard size.width > 0, size.height > 0 else { return nil }", "guard size.width >= 0 else { return nil }")],
    "V19 the width and height swapped": [("Viewport(width: Double(size.width), height: Double(size.height),", "Viewport(width: Double(size.height), height: Double(size.width),")],
    "V20 the deadline from the wrong time": [("held ? lastSentAt + Self.resizeInterval : nil", "held ? lastSentAt : nil")],
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
    b = subprocess.run(["swiftc", "-O", path, os.path.join(ROOT, "Sources/StreamProtocol/Input.swift"), os.path.join(ROOT, "Sources/StreamProtocol/Viewport.swift"),
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
