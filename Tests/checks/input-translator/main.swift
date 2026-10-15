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

print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks FAILED.")
exit(failures == 0 ? 0 : 1)
