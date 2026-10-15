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
/// - **Keys (#4):** a Mac virtual key code goes out as the HID usage of the same key, for every key
///   the Host maps (letters, digits, punctuation, Return, Escape, Delete, Tab, Space, F1–F12, the
///   navigation keys and arrows); AppKit's repeats go out as more downs, so a held key repeats on the
///   Host at this Mac's rate. A down carries the event's shift, control, option, command and caps lock
///   bits (CGEventFlags positions, as the protocol's), never AppKit's numeric pad, function or
///   device bits; an up carries the modifier keys still held. Keypad digits and operators go out as
///   the text they type (Enter as "\n"): the Host has no keypad keys. Keys it has no mapping for
///   (F13 and up, ISO and JIS extras, media keys, Help/Insert, keypad Clear, fn) send nothing. The
///   caps lock key itself sends nothing: its state rides on each down.
/// - **Modifier keys:** each of the eight (left and right control, shift, option, command) goes out
///   as its own key (HID 0xE0–0xE7), its down carrying what is held once it is down, its up what is
///   left, so the Host merges them into a click or a drag. Which one moved comes from AppKit's
///   device-dependent bits (left and right apart), else from the modifier's own bit.
/// - **Focus:** when the window stops being key, every button the Host holds goes up where the
///   pointer last was (held at the picture's edge), then every key, the last pressed first, then the
///   modifier keys. The click that brings an inactive window forward sends nothing, nor its up.
///
/// Later tickets grow it (the Viewport #6) with more entry points
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
    /// Where the pointer was last seen, in view points: where focus loss lets a held button go.
    private var lastPoint: CGPoint?
    /// Keys (HID usages, not modifiers) whose down the Host was sent and whose up it has not, in the
    /// order they went down.
    private var keysDown: [UInt16] = []
    /// Modifier keys (HID 0xE0–0xE7) the Host holds down, in the order they went down.
    private var modifiersDown: [UInt16] = []

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
        lastPoint = point
        guard let p = normalized(point, clamped: !held.isEmpty) else { return [] }
        return [.pointer(.move, x: p.x, y: p.y)]
    }

    /// A button pressed. `bringsWindowForward`: the click that makes an inactive window key, which
    /// only does that: neither it nor its up reaches the Host.
    mutating func mouseDown(_ button: Button, at point: CGPoint, bringsWindowForward: Bool = false) -> [InputEvent] {
        lastPoint = point
        guard !bringsWindowForward, let p = normalized(point) else { return [] }
        held.insert(button)
        return [.pointer(button == .left ? .leftDown : .rightDown, x: p.x, y: p.y)]
    }

    mutating func mouseUp(_ button: Button, at point: CGPoint) -> [InputEvent] {
        lastPoint = point
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

    // MARK: Keys

    /// A key pressed (`isRepeat`: AppKit's auto-repeat), with its Mac virtual key code and the event's
    /// modifier flags (`NSEvent.ModifierFlags.rawValue`).
    mutating func keyDown(_ keyCode: UInt16, flags: UInt64, isRepeat: Bool = false) -> [InputEvent] {
        if let text = Self.keypadText[keyCode] { return [.text(text)] }
        guard let usage = Self.hidUsages[keyCode] else { return [] }
        if !keysDown.contains(usage) { keysDown.append(usage) }
        return [.key(hidUsage: usage, down: true, modifiers: flags & Self.hostFlags)]
    }

    /// A key let go: its up, when the Host had its down, with the modifier keys still held.
    mutating func keyUp(_ keyCode: UInt16) -> [InputEvent] {
        guard let usage = Self.hidUsages[keyCode], let i = keysDown.firstIndex(of: usage) else { return [] }
        keysDown.remove(at: i)
        return [.key(hidUsage: usage, down: false, modifiers: heldFlags)]
    }

    /// A modifier key moved (AppKit's flagsChanged): its key code and the flags after it.
    mutating func flagsChanged(_ keyCode: UInt16, flags: UInt64) -> [InputEvent] {
        guard let modifier = Self.modifierKeys[keyCode] else { return [] }
        let isDown = flags & Self.deviceBits != 0 ? flags & modifier.device != 0 : flags & modifier.flag != 0
        if isDown {
            guard !modifiersDown.contains(modifier.usage) else { return [] }
            modifiersDown.append(modifier.usage)
        } else {
            guard let i = modifiersDown.firstIndex(of: modifier.usage) else { return [] }
            modifiersDown.remove(at: i)
        }
        return [.key(hidUsage: modifier.usage, down: isDown, modifiers: heldFlags)]
    }

    /// The window stopped being key: every button, key and modifier key the Host holds goes up.
    mutating func windowResignedKey() -> [InputEvent] {
        var out: [InputEvent] = []
        for button in [Button.left, .right] where held.contains(button) {
            held.remove(button)
            if let point = lastPoint, let p = normalized(point, clamped: true) {
                out.append(.pointer(button == .left ? .leftUp : .rightUp, x: p.x, y: p.y))
            }
        }
        while let usage = keysDown.popLast() {
            out.append(.key(hidUsage: usage, down: false, modifiers: heldFlags))
        }
        while let usage = modifiersDown.popLast() {
            out.append(.key(hidUsage: usage, down: false, modifiers: heldFlags))
        }
        return out
    }

    /// The flags of the modifier keys the Host holds.
    private var heldFlags: UInt64 {
        modifiersDown.reduce(0) { flags, usage in flags | (Self.modifierKeys.values.first { $0.usage == usage }?.flag ?? 0) }
    }

    /// The bits the Host takes on a key: caps lock, shift, control, option and command (CGEventFlags).
    static let hostFlags: UInt64 = 0x1F_0000
    /// AppKit's device-dependent modifier bits (IOLLEvent.h's NX_DEVICE…KEYMASK), left and right apart.
    static let deviceBits: UInt64 = 0x207F

    /// The eight modifier keys: Mac virtual key code → HID usage, its flag and its device bit.
    static let modifierKeys: [UInt16: (usage: UInt16, flag: UInt64, device: UInt64)] = [
        0x3B: (0xE0, 0x04_0000, 0x0001),   // left control
        0x38: (0xE1, 0x02_0000, 0x0002),   // left shift
        0x3A: (0xE2, 0x08_0000, 0x0020),   // left option
        0x37: (0xE3, 0x10_0000, 0x0008),   // left command
        0x3E: (0xE4, 0x04_0000, 0x2000),   // right control
        0x3C: (0xE5, 0x02_0000, 0x0004),   // right shift
        0x3D: (0xE6, 0x08_0000, 0x0040),   // right option
        0x36: (0xE7, 0x10_0000, 0x0010),   // right command
    ]

    /// The keypad's keys as the text they type.
    static let keypadText: [UInt16: String] = [
        0x52: "0", 0x53: "1", 0x54: "2", 0x55: "3", 0x56: "4", 0x57: "5", 0x58: "6", 0x59: "7", 0x5B: "8", 0x5C: "9",
        0x41: ".", 0x43: "*", 0x45: "+", 0x4B: "/", 0x4E: "-", 0x51: "=", 0x4C: "\n",
    ]

    /// Mac virtual key code (kVK_…) → USB HID usage, for the keys the Host maps (its KeyStrokes table).
    static let hidUsages: [UInt16: UInt16] = [
        // Letters A…Z
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A, 0x04: 0x0B,
        0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13,
        0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, 0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B,
        0x10: 0x1C, 0x06: 0x1D,
        // Digits 1…9, 0
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25,
        0x19: 0x26, 0x1D: 0x27,
        // Return, Escape, Delete, Tab, Space, then - = [ ] \ ; ' ` , . /
        0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C, 0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F,
        0x1E: 0x30, 0x2A: 0x31, 0x29: 0x33, 0x27: 0x34, 0x32: 0x35, 0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38,
        // F1…F12
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40, 0x64: 0x41,
        0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45,
        // Home, Page Up, Forward Delete, End, Page Down, Right, Left, Down, Up
        0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x77: 0x4D, 0x79: 0x4E, 0x7C: 0x4F, 0x7B: 0x50, 0x7D: 0x51,
        0x7E: 0x52,
    ]

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
