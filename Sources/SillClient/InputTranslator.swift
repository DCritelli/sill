import CoreGraphics
import Foundation
// In the app StreamProtocol is its own module; the input-translator check compiles this file together
// with Sources/StreamProtocol/Input.swift as one module, where there is nothing to import.
#if canImport(StreamProtocol)
import StreamProtocol
#endif

/// The Mac Client's input translator (the spec's Seam 1, DCritelli/sill#1): what happens on this Mac
/// in, `sill/1` input messages and the picture's geometry out. Pure: no AppKit in its interface, so
/// the view feeds it plain values and sends what it returns, in order.
///
/// Positions are the stream view's points with the origin at its top left (the view is flipped), so
/// y grows downward as the protocol's fractions do.
///
/// - **The picture:** fitted into the view, centred, with bars where the aspects differ
///   (`pictureRect`). The view draws the video there and gives the Host's cursor shape there.
/// - **Pointer:** positions go out as fractions of the picture, 0…1 each way. Moves over the bars
///   (or with no picture yet) are not sent while no button the Host knows of is held.
/// - **Buttons:** left and right go out as they come; double and triple clicks are left to the
///   Host, which counts them. A button pressed over the bars is not the Host's: neither its down
///   nor its up is sent.
/// - **Drags:** while a button the Host was sent is held, every move goes out, held at the
///   picture's edge when the pointer leaves it, and so does its up.
///
/// - **Scrolling (#5):** AppKit's deltas in points (already the content's motion: positive y moves
///   it down, positive x right, as the protocol's sign) go out as fractions of the picture. A
///   trackpad's phases become `scrollGesture` began and ended (a cancel ends it too), and its own
///   momentum phases momentumBegan and momentumEnded around the coast's deltas, so the Host gets
///   the trackpad's momentum rather than making one. A wheel (no phase, no momentum) sends plain
///   scrolls. A gesture begun over the bars is not the Host's, nor its momentum; one begun over the
///   picture is held at its edge until it ends. Fingers down during a coast end the coast first.
///
/// Later tickets grow it (keys and focus #4, the Viewport #6) with more entry points
/// of the same shape: a happening in, the messages out. Checked with swiftc
/// (Tests/checks/input-translator).
struct InputTranslator {
    enum Button: Hashable {
        case left, right
    }

    /// The stream view's size in points.
    var contentSize: CGSize = .zero
    /// The video frame's size (pixels or points: only its aspect counts), nil before the first one.
    var frameSize: CGSize?

    /// A trackpad scroll's phase, as AppKit's `NSEvent.phase` gives it (`none` for a wheel or a
    /// momentum event).
    enum GesturePhase {
        case none, mayBegin, began, changed, stationary, ended, cancelled
    }
    /// A trackpad scroll's momentum phase, as AppKit's `NSEvent.momentumPhase` gives it.
    enum MomentumPhase {
        case none, began, changed, ended
    }

    /// Buttons whose down the Host was sent and whose up it has not been.
    private var held: Set<Button> = []

    /// Where the trackpad scroll the Host was sent stands: nothing open, a gesture open, a gesture
    /// ended (its momentum may follow), or a coast open. A gesture begun over the bars leaves it idle.
    private enum Scrolling { case idle, gesture, ended, momentum }
    private var scrolling = Scrolling.idle

    /// Where the picture is drawn: the frame fitted into the view and centred, so bars fill the
    /// rest. nil while there is no frame or no room.
    var pictureRect: CGRect? {
        guard let frame = frameSize, frame.width > 0, frame.height > 0,
              contentSize.width > 0, contentSize.height > 0 else { return nil }
        let scale = min(contentSize.width / frame.width, contentSize.height / frame.height)
        let width = frame.width * scale, height = frame.height * scale
        return CGRect(x: (contentSize.width - width) / 2, y: (contentSize.height - height) / 2, width: width, height: height)
    }

    /// The pointer moved, with or without a button down (a drag).
    mutating func mouseMoved(to point: CGPoint) -> [InputEvent] {
        guard let p = normalized(point, clamped: !held.isEmpty) else { return [] }
        return [.pointer(.move, x: p.x, y: p.y)]
    }

    mutating func mouseDown(_ button: Button, at point: CGPoint) -> [InputEvent] {
        guard let p = normalized(point) else { return [] }
        held.insert(button)
        return [.pointer(button == .left ? .leftDown : .rightDown, x: p.x, y: p.y)]
    }

    mutating func mouseUp(_ button: Button, at point: CGPoint) -> [InputEvent] {
        guard held.remove(button) != nil, let p = normalized(point, clamped: true) else { return [] }
        return [.pointer(button == .left ? .leftUp : .rightUp, x: p.x, y: p.y)]
    }

    /// A scroll event: pixel deltas (points) at `point`, with its trackpad phase and momentum phase.
    mutating func scrolled(at point: CGPoint, dx: CGFloat, dy: CGFloat,
                           phase: GesturePhase, momentum: MomentumPhase) -> [InputEvent] {
        switch (phase, momentum) {
        case (.none, .none):   // a wheel: plain scrolls over the picture
            guard let p = normalized(point) else { return [] }
            return delta(at: p, dx: dx, dy: dy)
        case (.began, _):
            var out: [InputEvent] = []
            if scrolling == .momentum, let p = normalized(point, clamped: true) {
                out.append(.scrollGesture(.momentumEnded, x: p.x, y: p.y))
            }
            guard let p = normalized(point) else { scrolling = .idle; return out }
            scrolling = .gesture
            return out + [.scrollGesture(.began, x: p.x, y: p.y)] + delta(at: p, dx: dx, dy: dy)
        case (.changed, _):
            guard scrolling == .gesture, let p = normalized(point, clamped: true) else { return [] }
            return delta(at: p, dx: dx, dy: dy)
        case (.ended, _), (.cancelled, _):
            guard scrolling == .gesture, let p = normalized(point, clamped: true) else { return [] }
            scrolling = .ended
            return [.scrollGesture(.ended, x: p.x, y: p.y)]
        case (.none, .began):
            guard scrolling == .ended, let p = normalized(point, clamped: true) else { return [] }
            scrolling = .momentum
            return [.scrollGesture(.momentumBegan, x: p.x, y: p.y)] + delta(at: p, dx: dx, dy: dy)
        case (.none, .changed):
            guard scrolling == .momentum, let p = normalized(point, clamped: true) else { return [] }
            return delta(at: p, dx: dx, dy: dy)
        case (.none, .ended):
            guard scrolling == .momentum, let p = normalized(point, clamped: true) else { return [] }
            scrolling = .idle
            return [.scrollGesture(.momentumEnded, x: p.x, y: p.y)]
        case (.mayBegin, _), (.stationary, _):
            return []
        }
    }

    /// One scroll of `dx`, `dy` points as fractions of the picture, or nothing when it does not move.
    private func delta(at p: (x: Double, y: Double), dx: CGFloat, dy: CGFloat) -> [InputEvent] {
        guard let rect = pictureRect, dx != 0 || dy != 0 else { return [] }
        return [.scroll(x: p.x, y: p.y, dx: Double(dx / rect.width), dy: Double(dy / rect.height))]
    }

    /// `point` as fractions of the picture: nil outside it, or held at its edge when `clamped`.
    private func normalized(_ point: CGPoint, clamped: Bool = false) -> (x: Double, y: Double)? {
        guard let rect = pictureRect else { return nil }
        let x = Double((point.x - rect.minX) / rect.width), y = Double((point.y - rect.minY) / rect.height)
        if clamped { return (min(max(x, 0), 1), min(max(y, 0), 1)) }
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return (x, y)
    }
}
