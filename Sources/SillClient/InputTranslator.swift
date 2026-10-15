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
/// Later tickets grow it (keys and focus #4, scrolling #5, the Viewport #6) with more entry points
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

    /// Buttons whose down the Host was sent and whose up it has not been.
    private var held: Set<Button> = []

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

    /// `point` as fractions of the picture: nil outside it, or held at its edge when `clamped`.
    private func normalized(_ point: CGPoint, clamped: Bool = false) -> (x: Double, y: Double)? {
        guard let rect = pictureRect else { return nil }
        let x = Double((point.x - rect.minX) / rect.width), y = Double((point.y - rect.minY) / rect.height)
        if clamped { return (min(max(x, 0), 1), min(max(y, 0), 1)) }
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return (x, y)
    }
}
