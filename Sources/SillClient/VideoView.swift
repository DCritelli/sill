import AppKit
import AVFoundation
import CoreMedia
import StreamProtocol

/// The Mac Client's picture: an AppKit view hosting an AVSampleBufferDisplayLayer, which decodes
/// HEVC in hardware itself. The same steps as the iOS app's HEVCDisplayView (format description from
/// the parameter sets, one sample buffer per access unit, shown at once), without its pointer
/// sprite: the Mac Client sets the local cursor instead (DCritelli/sill#3).
///
/// The mouse and scrolling go through the input translator (InputTranslator.swift), which also says where the
/// picture is drawn, fitted with bars; the view only feeds it AppKit's events and hands on what it
/// returns (`onInput`). Over the picture the cursor is the Host's shape, through a cursor rect, so
/// AppKit swaps it as the pointer crosses the edge with nothing drawn by hand; elsewhere it is the
/// arrow. Flipped, so its points run from the top left as the translator's do.
///
/// Keys (DCritelli/sill#4): while this view is the key window's first responder, every key down, up
/// and modifier change goes to the translator through a local event monitor, which runs before
/// AppKit looks for a key equivalent, so ⌘-shortcuts (⌘C, ⌘W, ⌘Q, ⌘H…) go to the Host and not to Sill
/// Client's menus (they stay reachable with the mouse). macOS never hands an app the shortcuts it
/// keeps (⌘Tab, ⌘Space, Mission Control), so those stay local. When the window stops being key,
/// the translator lets go of everything held; the click that brings it forward reaches nothing.
final class VideoView: NSView {
    /// What the translator made of a mouse, scroll, key or focus event, in order. On main.
    var onInput: (([InputEvent]) -> Void)?

    private let displayLayer = AVSampleBufferDisplayLayer()
    /// On main.
    private var translator = InputTranslator()
    private var remoteCursor: NSCursor?
    private var trackingArea: NSTrackingArea?
    /// The local monitor that takes the keys while this view has them, and the key-window observer.
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// The event number of the click AppKit asked about in `acceptsFirstMouse`: the one that brings
    /// the window forward.
    private var firstMouseNumber: Int?
    /// Touched only on the session's queue (`apply`, `enqueue`), as the layer allows.
    private var formatDescription: CMVideoFormatDescription?
    private var lastParameterSets: Data?
    private var waitingForKeyframe = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // The layer is given the translator's picture rectangle, so its own fit and the
        // translator's agree whatever the layer would round.
        displayLayer.videoGravity = .resize
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Keys and focus

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        resignObserver = nil
        guard let window else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                  window.firstResponder === self else { return event }
            self.key(event)
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            guard let self else { return }
            self.hand(self.translator.windowResignedKey())
        }
    }

    private func key(_ event: NSEvent) {
        let flags = UInt64(event.modifierFlags.rawValue)
        switch event.type {
        case .keyDown: hand(translator.keyDown(event.keyCode, flags: flags, isRepeat: event.isARepeat))
        case .keyUp: hand(translator.keyUp(event.keyCode))
        case .flagsChanged: hand(translator.flagsChanged(event.keyCode, flags: flags))
        default: break
        }
    }

    /// A click into an inactive window: taken (so the view, not AppKit, decides), and remembered as
    /// the click that only brings the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        firstMouseNumber = event?.eventNumber
        return true
    }

    /// Whether this down only brings the window forward: the click `acceptsFirstMouse` was asked
    /// about, or any click while the window is not key (a right click does not activate it).
    private func bringsForward(_ event: NSEvent) -> Bool {
        defer { firstMouseNumber = nil }
        return event.eventNumber == firstMouseNumber || !(window?.isKeyWindow ?? false)
    }

    override func layout() {
        super.layout()
        translator.contentSize = bounds.size
        placePicture()
    }

    /// The layer where the translator says the picture goes, without an implicit animation, and the
    /// cursor rect with it.
    private func placePicture() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = translator.pictureRect ?? bounds
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    /// The video's size, from its format: the picture is fitted to its aspect. On main.
    private func setVideoSize(_ size: CGSize?) {
        guard translator.frameSize != size else { return }
        translator.frameSize = size
        placePicture()
    }

    // MARK: The cursor

    /// The Host's cursor shape (kind 14's CursorShapeBlob), shown over the picture. On main.
    func setCursorShape(_ blob: Data) {
        guard let shape = CursorShapeBlob.decode(blob), let image = NSImage(data: shape.png),
              shape.size.width > 0, shape.size.height > 0 else { return }
        image.size = shape.size   // the PNG is usually 2x: drawn at the Host's size in points
        let cursor = NSCursor(image: image, hotSpot: shape.hotspot)
        remoteCursor = cursor
        window?.invalidateCursorRects(for: self)
        // A cursor rect sets its cursor as the pointer enters it; one already inside gets the new
        // shape now, not at its next crossing.
        if let window, window.isKeyWindow, let rect = translator.pictureRect,
           rect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            cursor.set()
        }
    }

    override func resetCursorRects() {
        if let rect = translator.pictureRect, let remoteCursor { addCursorRect(rect, cursor: remoteCursor) }
    }

    // MARK: The mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    private func hand(_ events: [InputEvent]) { if !events.isEmpty { onInput?(events) } }

    override func mouseMoved(with event: NSEvent) { hand(translator.mouseMoved(to: point(event))) }
    override func mouseDragged(with event: NSEvent) { hand(translator.mouseMoved(to: point(event))) }
    override func rightMouseDragged(with event: NSEvent) { hand(translator.mouseMoved(to: point(event))) }
    override func mouseDown(with event: NSEvent) {
        hand(translator.mouseDown(.left, at: point(event), bringsWindowForward: bringsForward(event)))
    }
    override func mouseUp(with event: NSEvent) { hand(translator.mouseUp(.left, at: point(event))) }
    override func rightMouseDown(with event: NSEvent) {
        hand(translator.mouseDown(.right, at: point(event), bringsWindowForward: bringsForward(event)))
    }
    override func rightMouseUp(with event: NSEvent) { hand(translator.mouseUp(.right, at: point(event))) }

    /// Scrolling (DCritelli/sill#5): a trackpad's precise deltas are points; a wheel's are lines, so
    /// its point deltas come from the CGEvent (the pixels macOS would scroll a local view by).
    /// AppKit's deltas already follow the natural-scrolling setting, so they go to the translator
    /// as they are, with the phases it maps to the Host's gesture and momentum.
    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas, let cg = event.cgEvent {
            dx = cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            dy = cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        }
        hand(translator.scrolled(at: point(event), dx: dx, dy: dy,
                                 phase: Self.gesturePhase(event.phase), momentum: Self.momentumPhase(event.momentumPhase)))
    }

    private static func gesturePhase(_ phase: NSEvent.Phase) -> InputTranslator.GesturePhase {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.mayBegin) { return .mayBegin }
        if phase.contains(.stationary) { return .stationary }
        return .none
    }

    private static func momentumPhase(_ phase: NSEvent.Phase) -> InputTranslator.MomentumPhase {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
        if phase.contains(.ended) || phase.contains(.cancelled) { return .ended }
        return .none
    }

    /// A new format: the Host repeats its parameter sets with every keyframe, and only a real
    /// change (a new Source, a resize) needs a new description and a blank layer.
    func apply(_ ps: ParameterSets) {
        let encoded = ps.encoded()
        if encoded == lastParameterSets, formatDescription != nil { return }
        lastParameterSets = encoded
        var desc: CMVideoFormatDescription?
        let status: OSStatus = withPointers(to: ps.sets) { pointers in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: ps.sets.map(\.count), nalUnitHeaderLength: Int32(ps.nalUnitHeaderLength),
                extensions: nil, formatDescriptionOut: &desc)
        }
        guard status == noErr, let desc else { print("format description failed: \(status)"); return }
        formatDescription = desc
        waitingForKeyframe = true
        displayLayer.flushAndRemoveImage()
        let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
        let size = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
        DispatchQueue.main.async { [weak self] in self?.setVideoSize(size) }
    }

    func enqueue(_ data: Data, isKeyframe: Bool) {
        guard let desc = formatDescription else { return }
        if waitingForKeyframe {
            guard isKeyframe else { return }
            waitingForKeyframe = false
        }
        let count = data.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block,
              CMBlockBufferAssureBlockMemory(block) == noErr else { return }
        let replaced = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count)
        }
        guard replaced == noErr else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var size = count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: desc, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return }
        // Show each frame as soon as it decodes instead of scheduling by timestamp.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as NSArray?,
           let first = attachments.firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_DisplayImmediately as String] = true
        }
        if displayLayer.status == .failed {
            print("display layer failed: \(String(describing: displayLayer.error))")
            displayLayer.flush()
            waitingForKeyframe = true
            return
        }
        displayLayer.enqueue(sample)
    }

    /// Session over: drop the picture and the format, so the next one starts clean.
    func clear() {
        formatDescription = nil
        lastParameterSets = nil
        waitingForKeyframe = true
        displayLayer.flushAndRemoveImage()
        DispatchQueue.main.async { [weak self] in
            self?.setVideoSize(nil)
            self?.remoteCursor = nil
        }
    }

    private func withPointers<R>(to sets: [Data], _ body: ([UnsafePointer<UInt8>]) -> R) -> R {
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: p, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        return body(buffers.map { UnsafePointer($0) })
    }
}
