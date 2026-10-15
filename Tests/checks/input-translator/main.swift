// The input-translator check (DCritelli/sill#3): the Mac Client's InputTranslator
// (Sources/SillClient/InputTranslator.swift) with StreamProtocol's Input.swift, on its own:
//   swiftc -O Sources/SillClient/InputTranslator.swift Sources/StreamProtocol/Input.swift \
//     Tests/checks/input-translator/main.swift -o .build/checks/input-translator/check
// Positions are the view's points with the origin at the top left (the view is flipped). Expected
// values are worked by hand from the geometry, never recomputed the translator's way. Prints "ok" or
// "FAIL" per check; exits 1 on any failure.
import CoreGraphics
import Foundation

var failures = 0, checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    print(ok ? "ok   \(what())" : "FAIL (line \(line)) \(what())")
    if !ok { failures += 1 }
}
func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func size(_ w: CGFloat, _ h: CGFloat) -> CGSize { CGSize(width: w, height: h) }

/// A translator with a picture of `frame` in a view of `content`.
func translator(content: CGSize, frame: CGSize?) -> InputTranslator {
    var t = InputTranslator()
    t.contentSize = content
    t.frameSize = frame
    return t
}

// MARK: The picture's rectangle

do {
    // Same aspect (a 2x frame of an 800×500 view): the whole view, no bars.
    check(translator(content: size(800, 500), frame: size(1600, 1000)).pictureRect == CGRect(x: 0, y: 0, width: 800, height: 500),
          "same aspect: the picture fills the view")
    // A 16:10 frame in a 1000×500 view: 800 wide, bars of 100 left and right.
    check(translator(content: size(1000, 500), frame: size(1600, 1000)).pictureRect == CGRect(x: 100, y: 0, width: 800, height: 500),
          "a wider view: bars left and right")
    // The same frame in an 800×700 view: 500 tall, bars of 100 above and below.
    check(translator(content: size(800, 700), frame: size(1600, 1000)).pictureRect == CGRect(x: 0, y: 100, width: 800, height: 500),
          "a taller view: bars above and below")
    check(translator(content: size(800, 500), frame: nil).pictureRect == nil, "no frame yet: no picture")
    check(translator(content: size(800, 500), frame: size(0, 0)).pictureRect == nil, "an empty frame: no picture")
    check(translator(content: size(0, 0), frame: size(1600, 1000)).pictureRect == nil, "an empty view: no picture")
}

// MARK: Pointer positions, normalized within the picture

typealias T = InputTranslator
/// Fractions are worked to exact binary values here, so == is fair.
func move(_ x: Double, _ y: Double) -> InputEvent { .pointer(.move, x: x, y: y) }

do {
    // No bars: an 800×500 view, a 1600×1000 frame.
    var t = translator(content: size(800, 500), frame: size(1600, 1000))
    check(t.mouseMoved(to: pt(200, 125)) == [move(0.25, 0.25)], "no bars: a move a quarter in each way")
    check(t.mouseMoved(to: pt(0, 0)) == [move(0, 0)], "no bars: the top left corner is 0, 0 (y from the top)")
    check(t.mouseMoved(to: pt(800, 500)) == [move(1, 1)], "no bars: the bottom right corner is 1, 1")
    check(t.mouseDown(.left, at: pt(400, 250)) == [.pointer(.leftDown, x: 0.5, y: 0.5)], "a left click: down where it is")
    check(t.mouseUp(.left, at: pt(400, 250)) == [.pointer(.leftUp, x: 0.5, y: 0.5)], "a left click: up where it is")
    check(t.mouseDown(.right, at: pt(600, 375)) == [.pointer(.rightDown, x: 0.75, y: 0.75)], "a right click: down")
    check(t.mouseUp(.right, at: pt(600, 375)) == [.pointer(.rightUp, x: 0.75, y: 0.75)], "a right click: up")
    // A double click is two clicks, each sent as it is; the Host infers the count.
    var events: [InputEvent] = []
    for _ in 0..<2 { events += t.mouseDown(.left, at: pt(200, 125)); events += t.mouseUp(.left, at: pt(200, 125)) }
    check(events == [.pointer(.leftDown, x: 0.25, y: 0.25), .pointer(.leftUp, x: 0.25, y: 0.25),
                     .pointer(.leftDown, x: 0.25, y: 0.25), .pointer(.leftUp, x: 0.25, y: 0.25)],
          "a double click: two plain clicks, no count of their own")
}
do {
    // Bars left and right: a 1000×500 view, the picture at x 100…900.
    var t = translator(content: size(1000, 500), frame: size(1600, 1000))
    check(t.mouseMoved(to: pt(300, 125)) == [move(0.25, 0.25)], "bars left and right: a move counts from the picture's edge")
    check(t.mouseMoved(to: pt(100, 500)) == [move(0, 1)], "bars left and right: the picture's left edge is 0")
    check(t.mouseDown(.left, at: pt(700, 375)) == [.pointer(.leftDown, x: 0.75, y: 0.75)], "bars left and right: a click")
    _ = t.mouseUp(.left, at: pt(700, 375))
    // Bars above and below: an 800×700 view, the picture at y 100…600.
    var u = translator(content: size(800, 700), frame: size(1600, 1000))
    check(u.mouseMoved(to: pt(200, 225)) == [move(0.25, 0.25)], "bars above and below: a move counts from the picture's top")
    check(u.mouseMoved(to: pt(800, 600)) == [move(1, 1)], "bars above and below: the picture's bottom right is 1, 1")
}

// MARK: Nothing from the bars while no button is held

do {
    var t = translator(content: size(1000, 500), frame: size(1600, 1000))
    check(t.mouseMoved(to: pt(50, 250)) == [], "a move over the left bar: nothing")
    check(t.mouseMoved(to: pt(950, 250)) == [], "a move over the right bar: nothing")
    check(t.mouseMoved(to: pt(99.5, 250)) == [], "half a point outside the picture: nothing")
    var u = translator(content: size(800, 700), frame: size(1600, 1000))
    check(u.mouseMoved(to: pt(400, 50)) == [], "a move over the top bar: nothing")
    check(u.mouseMoved(to: pt(400, 650)) == [], "a move over the bottom bar: nothing")
    // A click on a bar reaches nothing, nor does its up, nor a move while that button is down.
    check(t.mouseDown(.left, at: pt(50, 250)) == [], "a click on a bar: no down")
    check(t.mouseMoved(to: pt(500, 250)) == [move(0.5, 0.5)],
          "with that button down, a move over the picture: a plain move (the Host has no button down)")
    check(t.mouseUp(.left, at: pt(500, 250)) == [], "its up over the picture: no up either")
    check(t.mouseMoved(to: pt(50, 250)) == [], "after it, a move over the bar: still nothing")
    // No picture yet: nothing at all.
    var v = translator(content: size(800, 500), frame: nil)
    check(v.mouseMoved(to: pt(400, 250)) == [] && v.mouseDown(.left, at: pt(400, 250)) == [] && v.mouseUp(.left, at: pt(400, 250)) == [],
          "no picture yet: nothing sent")
}

// MARK: A drag out of the picture, held at the edge

do {
    // Bars left and right: the picture at x 100…900 of a 1000×500 view.
    var t = translator(content: size(1000, 500), frame: size(1600, 1000))
    check(t.mouseDown(.left, at: pt(500, 250)) == [.pointer(.leftDown, x: 0.5, y: 0.5)], "a drag starts in the picture")
    check(t.mouseMoved(to: pt(300, 125)) == [move(0.25, 0.25)], "the drag inside: where it is")
    check(t.mouseMoved(to: pt(50, 125)) == [move(0, 0.25)], "the drag over the left bar: held at the left edge")
    check(t.mouseMoved(to: pt(-200, 375)) == [move(0, 0.75)], "the drag beyond the view to the left: still the left edge")
    check(t.mouseMoved(to: pt(1300, -40)) == [move(1, 0)], "beyond the top right: the top right corner")
    check(t.mouseMoved(to: pt(700, 900)) == [move(0.75, 1)], "below the view: the bottom edge")
    check(t.mouseUp(.left, at: pt(-200, 125)) == [.pointer(.leftUp, x: 0, y: 0.25)], "let go outside: the up at the edge")
    check(t.mouseMoved(to: pt(50, 125)) == [], "after the drag, a move over the bar: nothing again")
}
do {
    // A right drag, and two buttons: the drag lasts while either is held.
    var t = translator(content: size(800, 700), frame: size(1600, 1000))   // the picture at y 100…600
    _ = t.mouseDown(.right, at: pt(400, 350))
    check(t.mouseMoved(to: pt(200, 20)) == [move(0.25, 0)], "a right drag over the top bar: held at the top edge")
    check(t.mouseUp(.right, at: pt(200, 690)) == [.pointer(.rightUp, x: 0.25, y: 1)], "a right drag let go below: the up at the bottom edge")
    _ = t.mouseDown(.left, at: pt(400, 350))
    _ = t.mouseDown(.right, at: pt(400, 350))
    check(t.mouseUp(.left, at: pt(400, 650)) == [.pointer(.leftUp, x: 0.5, y: 1)], "two held, the left let go below: at the edge")
    check(t.mouseMoved(to: pt(600, 680)) == [move(0.75, 1)], "the right still held: the drag still holds at the edge")
    check(t.mouseUp(.right, at: pt(600, 680)) == [.pointer(.rightUp, x: 0.75, y: 1)], "the right let go: its up at the edge")
    check(t.mouseMoved(to: pt(600, 680)) == [], "none held: the bar is quiet again")
}
do {
    // A button pressed on a bar does not start a drag, even with another held from the picture.
    var t = translator(content: size(1000, 500), frame: size(1600, 1000))
    _ = t.mouseDown(.right, at: pt(20, 250))
    check(t.mouseMoved(to: pt(20, 300)) == [], "a button pressed on a bar: moving on the bar sends nothing")
    check(t.mouseUp(.right, at: pt(20, 300)) == [], "and its up nothing")
}

// MARK: Scrolling (DCritelli/sill#5)

/// AppKit's scroll deltas (scrollingDeltaX/Y, in points) are already the content's motion: positive
/// y moves the content down (with natural scrolling, the fingers dragged down), positive x moves it
/// right. The protocol's sign is the same, so a delta goes out as the same sign, a fraction of the
/// picture's size.
func scroll(_ x: Double, _ y: Double, _ dx: Double, _ dy: Double) -> InputEvent { .scroll(x: x, y: y, dx: dx, dy: dy) }
func gesture(_ phase: ScrollPhase, _ x: Double, _ y: Double) -> InputEvent { .scrollGesture(phase, x: x, y: y) }

do {
    // A trackpad flick with no bars: an 800×500 view, the pointer at the middle.
    var t = translator(content: size(800, 500), frame: size(1600, 1000))
    let mid = pt(400, 250)
    check(t.scrolled(at: mid, dx: 0, dy: 0, phase: .mayBegin, momentum: .none) == [],
          "fingers resting (mayBegin): nothing yet")
    check(t.scrolled(at: mid, dx: 0, dy: 125, phase: .began, momentum: .none) == [gesture(.began, 0.5, 0.5), scroll(0.5, 0.5, 0, 0.25)],
          "a trackpad scroll begins: began, then its delta (125 of 500 points down is 0.25)")
    check(t.scrolled(at: mid, dx: 200, dy: -250, phase: .changed, momentum: .none) == [scroll(0.5, 0.5, 0.25, -0.5)],
          "changed: both axes, each a fraction of the picture, signs kept")
    check(t.scrolled(at: mid, dx: 0, dy: 0, phase: .stationary, momentum: .none) == [],
          "fingers holding still: nothing")
    check(t.scrolled(at: mid, dx: 0, dy: 0, phase: .ended, momentum: .none) == [gesture(.ended, 0.5, 0.5)],
          "the fingers lift: ended")
    check(t.scrolled(at: mid, dx: 0, dy: 50, phase: .none, momentum: .began) == [gesture(.momentumBegan, 0.5, 0.5), scroll(0.5, 0.5, 0, 0.1)],
          "the trackpad's own momentum begins: momentumBegan, then its delta")
    check(t.scrolled(at: mid, dx: -100, dy: 0, phase: .none, momentum: .changed) == [scroll(0.5, 0.5, -0.125, 0)],
          "momentum continues: a leftward delta stays negative")
    check(t.scrolled(at: mid, dx: 0, dy: 0, phase: .none, momentum: .ended) == [gesture(.momentumEnded, 0.5, 0.5)],
          "momentum ends: momentumEnded")
    check(t.scrolled(at: mid, dx: 0, dy: 0, phase: .none, momentum: .ended) == [], "a second momentum end: nothing")
    check(t.scrolled(at: mid, dx: 0, dy: 125, phase: .began, momentum: .none) == [gesture(.began, 0.5, 0.5), scroll(0.5, 0.5, 0, 0.25)],
          "the next gesture after a finished coast: began alone, no stray momentumEnded")
}
do {
    // A wheel mouse: no phase, no momentum: plain scrolls, never a gesture.
    var t = translator(content: size(800, 500), frame: size(1600, 1000))
    check(t.scrolled(at: pt(200, 125), dx: 0, dy: 50, phase: .none, momentum: .none) == [scroll(0.25, 0.25, 0, 0.1)],
          "a wheel tick down: a plain scroll, no gesture")
    check(t.scrolled(at: pt(200, 125), dx: 0, dy: -50, phase: .none, momentum: .none) == [scroll(0.25, 0.25, 0, -0.1)],
          "a wheel tick up: negative")
    check(t.scrolled(at: pt(200, 125), dx: 400, dy: 0, phase: .none, momentum: .none) == [scroll(0.25, 0.25, 0.5, 0)],
          "a horizontal wheel (shift-scroll or a tilt wheel): dx alone, a fraction of the width")
    check(t.scrolled(at: pt(200, 125), dx: 0, dy: 0, phase: .none, momentum: .none) == [],
          "a scroll event with no motion: nothing")
}
do {
    // With bars: fractions of the picture, not the view. A 1000×500 view, the picture 800×500 at x 100.
    var t = translator(content: size(1000, 500), frame: size(1600, 1000))
    check(t.scrolled(at: pt(300, 375), dx: 200, dy: 250, phase: .none, momentum: .none) == [scroll(0.25, 0.75, 0.25, 0.5)],
          "bars left and right: the position from the picture's edge, dx a fraction of the picture's 800")
    // A 800×700 view, the picture 800×500 at y 100: dy a fraction of 500, not 700.
    var u = translator(content: size(800, 700), frame: size(1600, 1000))
    check(u.scrolled(at: pt(400, 225), dx: 0, dy: 125, phase: .none, momentum: .none) == [scroll(0.5, 0.25, 0, 0.25)],
          "bars above and below: dy a fraction of the picture's 500")
    // Over a bar: a wheel sends nothing, nor does a gesture that begins there, nor its momentum.
    check(t.scrolled(at: pt(50, 250), dx: 0, dy: 50, phase: .none, momentum: .none) == [], "a wheel over a bar: nothing")
    check(t.scrolled(at: pt(50, 250), dx: 0, dy: 50, phase: .began, momentum: .none) == [], "a gesture begun over a bar: nothing")
    check(t.scrolled(at: pt(500, 250), dx: 0, dy: 50, phase: .changed, momentum: .none) == [],
          "that gesture moving over the picture: still not the Host's")
    check(t.scrolled(at: pt(500, 250), dx: 0, dy: 0, phase: .ended, momentum: .none) == [], "its end: nothing")
    check(t.scrolled(at: pt(500, 250), dx: 0, dy: 50, phase: .none, momentum: .began) == [] &&
          t.scrolled(at: pt(500, 250), dx: 0, dy: 0, phase: .none, momentum: .ended) == [],
          "its momentum: nothing")
    // No picture yet: nothing.
    var v = translator(content: size(800, 500), frame: nil)
    check(v.scrolled(at: pt(400, 250), dx: 0, dy: 50, phase: .none, momentum: .none) == [], "no picture yet: no scroll")
}
do {
    // A gesture begun on the picture keeps going when the pointer drifts over a bar: held at the edge.
    var t = translator(content: size(1000, 500), frame: size(1600, 1000))   // the picture at x 100…900
    _ = t.scrolled(at: pt(500, 250), dx: 0, dy: 50, phase: .began, momentum: .none)
    check(t.scrolled(at: pt(40, 125), dx: 0, dy: 50, phase: .changed, momentum: .none) == [scroll(0, 0.25, 0, 0.1)],
          "a gesture's pointer over the left bar: held at the edge")
    check(t.scrolled(at: pt(40, 125), dx: 0, dy: 0, phase: .ended, momentum: .none) == [gesture(.ended, 0, 0.25)],
          "and it ends there, at the edge")
    check(t.scrolled(at: pt(960, 375), dx: 0, dy: 50, phase: .none, momentum: .began) == [gesture(.momentumBegan, 1, 0.75), scroll(1, 0.75, 0, 0.1)],
          "its momentum over the right bar: still the Host's, at the edge")
    check(t.scrolled(at: pt(960, 375), dx: 0, dy: 0, phase: .none, momentum: .ended) == [gesture(.momentumEnded, 1, 0.75)],
          "its momentum ends at the edge")
    check(t.scrolled(at: pt(960, 375), dx: 0, dy: 50, phase: .none, momentum: .none) == [],
          "after it, a wheel over the bar: nothing again")
}
do {
    // A cancelled gesture closes as ended; a new gesture during momentum ends the momentum first.
    var t = translator(content: size(800, 500), frame: size(1600, 1000))
    let mid = pt(400, 250)
    _ = t.scrolled(at: mid, dx: 0, dy: 50, phase: .began, momentum: .none)
    check(t.scrolled(at: mid, dx: 0, dy: 0, phase: .cancelled, momentum: .none) == [gesture(.ended, 0.5, 0.5)],
          "a gesture cancelled: ended, so the Host closes it")
    check(t.scrolled(at: mid, dx: 0, dy: 0, phase: .mayBegin, momentum: .none) == [] &&
          t.scrolled(at: mid, dx: 0, dy: 0, phase: .cancelled, momentum: .none) == [],
          "fingers that rest and lift without scrolling (mayBegin, cancelled): nothing")
    _ = t.scrolled(at: mid, dx: 0, dy: 50, phase: .began, momentum: .none)
    _ = t.scrolled(at: mid, dx: 0, dy: 0, phase: .ended, momentum: .none)
    _ = t.scrolled(at: mid, dx: 0, dy: 50, phase: .none, momentum: .began)
    check(t.scrolled(at: mid, dx: 0, dy: 125, phase: .began, momentum: .none) ==
          [gesture(.momentumEnded, 0.5, 0.5), gesture(.began, 0.5, 0.5), scroll(0.5, 0.5, 0, 0.25)],
          "fingers down during momentum: momentumEnded, then the new gesture")
    check(t.scrolled(at: mid, dx: 0, dy: 0, phase: .none, momentum: .ended) == [],
          "the old momentum's late end: nothing more")
    check(t.scrolled(at: mid, dx: 0, dy: 0, phase: .ended, momentum: .none) == [gesture(.ended, 0.5, 0.5)],
          "the new gesture ends")
    check(t.scrolled(at: mid, dx: 0, dy: 50, phase: .none, momentum: .changed) == [],
          "a momentum delta with no momentum begun: nothing")
}


// MARK: Keys (DCritelli/sill#4)

/// A key event as the Host takes it: a HID usage, down or up, and the CGEventFlags bits it carries.
func key(_ usage: UInt16, _ down: Bool, _ modifiers: UInt64 = 0) -> InputEvent { .key(hidUsage: usage, down: down, modifiers: modifiers) }
// CGEventFlags (and NSEvent.ModifierFlags) bits: the protocol's modifiers.
let capsBit: UInt64 = 1 << 16, shiftBit: UInt64 = 1 << 17, controlBit: UInt64 = 1 << 18
let optionBit: UInt64 = 1 << 19, commandBit: UInt64 = 1 << 20
// Bits AppKit sets that are not the Host's: numeric pad and function (on the arrows and F-keys), and
// the device-dependent left/right bits in the low word (IOLLEvent.h's NX_DEVICE…KEYMASK).
let numericPadBit: UInt64 = 1 << 21, functionBit: UInt64 = 1 << 23
let devLShift: UInt64 = 0x02, devRShift: UInt64 = 0x04, devLCmd: UInt64 = 0x08, devRCmd: UInt64 = 0x10
let devLAlt: UInt64 = 0x20, devLCtl: UInt64 = 0x01, devRCtl: UInt64 = 0x2000, devRAlt: UInt64 = 0x40

do {
    // The mapping, each pair from two independent sources: the Mac's virtual key code (HIToolbox's
    // Events.h, kVK_…) and the USB HID usage for the same key (HID Usage Tables, Keyboard page).
    let letters: [(String, UInt16)] = [("A", 0x00), ("B", 0x0B), ("C", 0x08), ("D", 0x02), ("E", 0x0E), ("F", 0x03),
        ("G", 0x05), ("H", 0x04), ("I", 0x22), ("J", 0x26), ("K", 0x28), ("L", 0x25), ("M", 0x2E), ("N", 0x2D),
        ("O", 0x1F), ("P", 0x23), ("Q", 0x0C), ("R", 0x0F), ("S", 0x01), ("T", 0x11), ("U", 0x20), ("V", 0x09),
        ("W", 0x0D), ("X", 0x07), ("Y", 0x10), ("Z", 0x06)]
    var table: [(String, UInt16, UInt16)] = letters.enumerated().map { ($0.element.0, $0.element.1, UInt16(0x04 + $0.offset)) }
    let digits: [(String, UInt16)] = [("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("5", 0x17), ("6", 0x16),
        ("7", 0x1A), ("8", 0x1C), ("9", 0x19), ("0", 0x1D)]
    table += digits.enumerated().map { ($0.element.0, $0.element.1, UInt16(0x1E + $0.offset)) }
    table += [("Return", 0x24, 0x28), ("Escape", 0x35, 0x29), ("Delete", 0x33, 0x2A), ("Tab", 0x30, 0x2B),
              ("Space", 0x31, 0x2C), ("-", 0x1B, 0x2D), ("=", 0x18, 0x2E), ("[", 0x21, 0x2F), ("]", 0x1E, 0x30),
              ("\\", 0x2A, 0x31), (";", 0x29, 0x33), ("'", 0x27, 0x34), ("`", 0x32, 0x35), (",", 0x2B, 0x36),
              (".", 0x2F, 0x37), ("/", 0x2C, 0x38),
              ("F1", 0x7A, 0x3A), ("F2", 0x78, 0x3B), ("F3", 0x63, 0x3C), ("F4", 0x76, 0x3D), ("F5", 0x60, 0x3E),
              ("F6", 0x61, 0x3F), ("F7", 0x62, 0x40), ("F8", 0x64, 0x41), ("F9", 0x65, 0x42), ("F10", 0x6D, 0x43),
              ("F11", 0x67, 0x44), ("F12", 0x6F, 0x45),
              ("Home", 0x73, 0x4A), ("Page Up", 0x74, 0x4B), ("Forward Delete", 0x75, 0x4C), ("End", 0x77, 0x4D),
              ("Page Down", 0x79, 0x4E), ("Right", 0x7C, 0x4F), ("Left", 0x7B, 0x50), ("Down", 0x7D, 0x51), ("Up", 0x7E, 0x52)]
    var t = InputTranslator()
    var wrong: [String] = []
    for (name, code, usage) in table {
        let down = t.keyDown(code, flags: 0), up = t.keyUp(code)
        if down != [key(usage, true)] || up != [key(usage, false)] { wrong.append("\(name): \(down) \(up)") }
    }
    check(wrong.isEmpty, "every key the Host takes: its HID usage, down then up (\(table.count) keys) \(wrong)")
}
do {
    // Keys the Host has no mapping for: nothing, down or up, and nothing left held.
    let dropped: [(String, UInt16)] = [("F13", 0x69), ("F14", 0x6B), ("F15", 0x71), ("F16", 0x6A), ("F17", 0x40),
        ("F18", 0x4F), ("F19", 0x50), ("F20", 0x5A), ("ISO §", 0x0A), ("JIS ¥", 0x5D), ("JIS _", 0x5E),
        ("JIS keypad comma", 0x5F), ("Eisu", 0x66), ("Kana", 0x68), ("Help/Insert", 0x72), ("Volume up", 0x48),
        ("Volume down", 0x49), ("Mute", 0x4A), ("Context menu", 0x6E), ("Keypad clear", 0x47), ("Unknown 0x7F", 0x7F)]
    var t = InputTranslator()
    var sent: [String] = []
    for (name, code) in dropped {
        let events = t.keyDown(code, flags: 0) + t.keyDown(code, flags: 0, isRepeat: true) + t.keyUp(code)
        if !events.isEmpty { sent.append("\(name): \(events)") }
    }
    check(sent.isEmpty, "keys the Host has no mapping for send nothing (\(dropped.count) keys) \(sent)")
    check(t.windowResignedKey() == [], "and none of them is held to release")
}
do {
    // The keypad types its characters as text (the Host has no keypad keys); its up sends nothing.
    let keypad: [(UInt16, String)] = [(0x52, "0"), (0x53, "1"), (0x54, "2"), (0x55, "3"), (0x56, "4"), (0x57, "5"),
        (0x58, "6"), (0x59, "7"), (0x5B, "8"), (0x5C, "9"), (0x41, "."), (0x43, "*"), (0x45, "+"), (0x4B, "/"),
        (0x4E, "-"), (0x51, "="), (0x4C, "\n")]
    var t = InputTranslator()
    var wrong: [String] = []
    for (code, text) in keypad {
        let down = t.keyDown(code, flags: numericPadBit), up = t.keyUp(code)
        if down != [.text(text)] || up != [] { wrong.append("\(code): \(down) \(up)") }
    }
    check(wrong.isEmpty, "keypad digits and operators as text, Enter as a newline (\(keypad.count) keys) \(wrong)")
    check(t.keyDown(0x5C, flags: numericPadBit, isRepeat: true) == [.text("9")], "a keypad key held: its repeats type again")
    check(t.windowResignedKey() == [], "keypad keys are never held on the Host")
}
do {
    // Downs carry the Host's modifier bits from the event's flags and nothing else; repeats go on.
    var t = InputTranslator()
    check(t.keyDown(0x7B, flags: numericPadBit | functionBit) == [key(0x50, true)],
          "an arrow: AppKit's numeric pad and function bits are not sent")
    check(t.keyDown(0x7B, flags: numericPadBit | functionBit, isRepeat: true) == [key(0x50, true)],
          "the arrow held: each repeat a down, so the Host's text field repeats it")
    check(t.keyUp(0x7B) == [key(0x50, false)], "the arrow let go: one up")
    check(t.windowResignedKey() == [], "after its repeats and its one up, nothing is held")
    check(t.keyDown(0x33, flags: 0, isRepeat: true) == [key(0x2A, true)], "Delete repeating: a down each time")
    _ = t.keyUp(0x33)
    check(t.keyUp(0x00) == [], "an up whose down the Host never had: nothing")
    check(t.keyDown(0x00, flags: capsBit) == [key(0x04, true, capsBit)], "caps lock on: A's down carries the caps bit")
    _ = t.keyUp(0x00)
    check(t.flagsChanged(0x39, flags: capsBit) == [] && t.flagsChanged(0x39, flags: 0) == [],
          "the caps lock key itself: nothing (its state rides on each key's down)")
    check(t.flagsChanged(0x3F, flags: 1 << 23) == [] && t.flagsChanged(0x3F, flags: 0) == [], "fn alone: nothing")
}

// MARK: Modifier keys as their own key events

do {
    var t = InputTranslator()
    check(t.flagsChanged(0x38, flags: shiftBit | devLShift) == [key(0xE1, true, shiftBit)], "left shift down: its own key, shift on")
    check(t.keyDown(0x00, flags: shiftBit | devLShift) == [key(0x04, true, shiftBit)], "A with shift: its down carries shift")
    check(t.keyUp(0x00) == [key(0x04, false, shiftBit)], "A's up: the shift still held")
    check(t.flagsChanged(0x38, flags: 0) == [key(0xE1, false, 0)], "left shift up: its own key, nothing held")
    // Each modifier key, left and right.
    let mods: [(String, UInt16, UInt16, UInt64, UInt64)] = [
        ("left control", 0x3B, 0xE0, controlBit, devLCtl), ("left shift", 0x38, 0xE1, shiftBit, devLShift),
        ("left option", 0x3A, 0xE2, optionBit, devLAlt), ("left command", 0x37, 0xE3, commandBit, devLCmd),
        ("right control", 0x3E, 0xE4, controlBit, devRCtl), ("right shift", 0x3C, 0xE5, shiftBit, devRShift),
        ("right option", 0x3D, 0xE6, optionBit, devRAlt), ("right command", 0x36, 0xE7, commandBit, devRCmd)]
    var wrong: [String] = []
    for (name, code, usage, bit, dev) in mods {
        let down = t.flagsChanged(code, flags: bit | dev), up = t.flagsChanged(code, flags: 0)
        if down != [key(usage, true, bit)] || up != [key(usage, false, 0)] { wrong.append("\(name): \(down) \(up)") }
    }
    check(wrong.isEmpty, "each modifier key, left and right, down and up as its own HID usage \(wrong)")
}
do {
    // Both shifts: letting one go keeps the other, and shift, held.
    var t = InputTranslator()
    _ = t.flagsChanged(0x38, flags: shiftBit | devLShift)
    check(t.flagsChanged(0x3C, flags: shiftBit | devLShift | devRShift) == [key(0xE5, true, shiftBit)], "right shift too")
    check(t.flagsChanged(0x38, flags: shiftBit | devRShift) == [key(0xE1, false, shiftBit)],
          "left shift let go, right still down: left's up, shift still held")
    check(t.flagsChanged(0x3C, flags: 0) == [key(0xE5, false, 0)], "right shift let go: nothing held")
    // Both controls: the left let go while the right (whose device bit is 0x2000, apart from the
    // others) stays down.
    _ = t.flagsChanged(0x3B, flags: controlBit | devLCtl)
    _ = t.flagsChanged(0x3E, flags: controlBit | devLCtl | devRCtl)
    check(t.flagsChanged(0x3B, flags: controlBit | devRCtl) == [key(0xE0, false, controlBit)],
          "left control let go, right still down: left's up, control still held")
    check(t.flagsChanged(0x3E, flags: 0) == [key(0xE4, false, 0)], "right control let go")
    _ = t.flagsChanged(0x38, flags: shiftBit | devLShift)
    check(t.flagsChanged(0x38, flags: shiftBit | devLShift | capsBit) == [], "a second report of a modifier already down: nothing")
    _ = t.flagsChanged(0x38, flags: 0)
    // ⌘ then ⌥ held together: each down carries what is held by then, each up what is left.
    check(t.flagsChanged(0x37, flags: commandBit | devLCmd) == [key(0xE3, true, commandBit)], "⌘ down")
    check(t.flagsChanged(0x3A, flags: commandBit | optionBit | devLCmd | devLAlt) == [key(0xE2, true, commandBit | optionBit)],
          "⌥ down with ⌘ held: both")
    check(t.keyDown(0x0D, flags: commandBit | optionBit | devLCmd | devLAlt) == [key(0x1A, true, commandBit | optionBit)],
          "⌘⌥W: W's down carries both")
    check(t.keyUp(0x0D) == [key(0x1A, false, commandBit | optionBit)], "W up")
    check(t.flagsChanged(0x37, flags: optionBit | devLAlt) == [key(0xE3, false, optionBit)], "⌘ up first: ⌥ left")
    check(t.flagsChanged(0x3A, flags: 0) == [key(0xE2, false, 0)], "⌥ up: nothing left")
    check(t.flagsChanged(0x3A, flags: 0) == [], "a modifier up the Host never had down: nothing")
}
do {
    // Without the device bits (a keyboard or event that leaves them out), the modifier's own bit decides.
    var t = InputTranslator()
    check(t.flagsChanged(0x3B, flags: controlBit) == [key(0xE0, true, controlBit)], "control down, no device bits")
    check(t.flagsChanged(0x3B, flags: 0) == [key(0xE0, false, 0)], "control up, no device bits")
}
do {
    // Modified clicks and drags: the modifier keys go first, so the Host merges them into the click.
    var t = translator(content: size(800, 500), frame: size(1600, 1000))
    var events = t.flagsChanged(0x38, flags: shiftBit | devLShift)
    events += t.mouseDown(.left, at: pt(200, 125)) + t.mouseUp(.left, at: pt(200, 125))
    events += t.flagsChanged(0x38, flags: 0)
    check(events == [key(0xE1, true, shiftBit), .pointer(.leftDown, x: 0.25, y: 0.25), .pointer(.leftUp, x: 0.25, y: 0.25), key(0xE1, false, 0)],
          "shift-click: shift down, the click, shift up")
    events = t.flagsChanged(0x3A, flags: optionBit | devLAlt) + t.mouseDown(.left, at: pt(200, 125))
    events += t.mouseMoved(to: pt(600, 375)) + t.mouseUp(.left, at: pt(600, 375)) + t.flagsChanged(0x3A, flags: 0)
    check(events == [key(0xE2, true, optionBit), .pointer(.leftDown, x: 0.25, y: 0.25), move(0.75, 0.75),
                     .pointer(.leftUp, x: 0.75, y: 0.75), key(0xE2, false, 0)],
          "option-drag: option held through the drag")
    events = t.flagsChanged(0x3B, flags: controlBit | devLCtl) + t.mouseDown(.left, at: pt(400, 250)) + t.mouseUp(.left, at: pt(400, 250))
    events += t.flagsChanged(0x3B, flags: 0)
    check(events == [key(0xE0, true, controlBit), .pointer(.leftDown, x: 0.5, y: 0.5), .pointer(.leftUp, x: 0.5, y: 0.5), key(0xE0, false, 0)],
          "control-click: a left click with control held, for the Host to make secondary")
}

// MARK: Focus

do {
    // Switching away mid-chord, with a drag held: everything goes up on the Host.
    var t = translator(content: size(1000, 500), frame: size(1600, 1000))   // the picture at x 100…900
    _ = t.flagsChanged(0x37, flags: commandBit | devLCmd)
    _ = t.flagsChanged(0x38, flags: commandBit | shiftBit | devLCmd | devLShift)
    _ = t.keyDown(0x01, flags: commandBit | shiftBit | devLCmd | devLShift)   // ⌘⇧S held
    _ = t.keyDown(0x7E, flags: commandBit | shiftBit | functionBit)          // and ↑
    _ = t.mouseDown(.left, at: pt(500, 250))
    _ = t.mouseMoved(to: pt(40, 125))                                      // dragged over the left bar
    check(t.windowResignedKey() == [.pointer(.leftUp, x: 0, y: 0.25), key(0x52, false, commandBit | shiftBit),
                                    key(0x16, false, commandBit | shiftBit), key(0xE1, false, commandBit), key(0xE3, false, 0)],
          "focus lost mid-chord: the button up where it was, then the keys last pressed first, then the modifiers")
    check(t.windowResignedKey() == [], "focus lost again: nothing more")
    check(t.keyUp(0x01) == [] && t.keyUp(0x7E) == [] && t.flagsChanged(0x37, flags: 0) == [] && t.mouseUp(.left, at: pt(500, 250)) == [],
          "their real ups later: nothing (the Host already has them up)")
    check(t.mouseMoved(to: pt(40, 125)) == [], "no drag any more: a move over the bar sends nothing")
    // Both buttons: both go up.
    _ = t.mouseDown(.left, at: pt(500, 250))
    _ = t.mouseDown(.right, at: pt(700, 375))
    let ups = t.windowResignedKey()
    check(ups.count == 2 && ups.contains(.pointer(.leftUp, x: 0.75, y: 0.75)) && ups.contains(.pointer(.rightUp, x: 0.75, y: 0.75)),
          "two buttons held: both up, at the pointer's last place \(ups)")
}
do {
    // The first click into an inactive window only brings it forward.
    var t = translator(content: size(800, 500), frame: size(1600, 1000))
    check(t.mouseDown(.left, at: pt(400, 250), bringsWindowForward: true) == [], "the first click: no down")
    check(t.mouseUp(.left, at: pt(400, 250)) == [], "its up: swallowed too")
    check(t.mouseDown(.right, at: pt(400, 250), bringsWindowForward: true) == [] && t.mouseUp(.right, at: pt(400, 250)) == [],
          "a first right click: nothing either")
    check(t.mouseDown(.left, at: pt(200, 125)) == [.pointer(.leftDown, x: 0.25, y: 0.25)], "the next click: the Host's")
    check(t.mouseUp(.left, at: pt(200, 125)) == [.pointer(.leftUp, x: 0.25, y: 0.25)], "and its up")
    // A first click held into a drag never becomes the Host's drag.
    _ = t.mouseDown(.left, at: pt(400, 250), bringsWindowForward: true)
    check(t.mouseMoved(to: pt(-50, 250)) == [], "dragging off the picture after the first click: no drag held at the edge")
    check(t.windowResignedKey() == [], "focus lost after it: no button to release")
}

print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks FAILED.")
exit(failures == 0 ? 0 : 1)
