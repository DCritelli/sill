import AppKit
import AVFoundation
import CoreMedia
import StreamProtocol

/// The Mac Client's picture: an AppKit view hosting an AVSampleBufferDisplayLayer, which decodes
/// HEVC in hardware itself. The same steps as the iOS app's HEVCDisplayView (format description from
/// the parameter sets, one sample buffer per access unit, shown at once), without its pointer
/// sprite: the Mac Client sets the local cursor instead (DCritelli/sill#3).
///
/// The mouse goes through the input translator (InputTranslator.swift), which also says where the
/// picture is drawn, fitted with bars; the view only feeds it AppKit's events and hands on what it
/// returns (`onInput`). Over the picture the cursor is the Host's shape, through a cursor rect, so
/// AppKit swaps it as the pointer crosses the edge with nothing drawn by hand; elsewhere it is the
/// arrow. Flipped, so its points run from the top left as the translator's do.
final class VideoView: NSView {
    /// What the translator made of a mouse event, in order. On main.
    var onInput: (([InputEvent]) -> Void)?

    private let displayLayer = AVSampleBufferDisplayLayer()
    /// On main.
    private var translator = InputTranslator()
    private var remoteCursor: NSCursor?
    private var trackingArea: NSTrackingArea?
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
    override func mouseDown(with event: NSEvent) { hand(translator.mouseDown(.left, at: point(event))) }
    override func mouseUp(with event: NSEvent) { hand(translator.mouseUp(.left, at: point(event))) }
    override func rightMouseDown(with event: NSEvent) { hand(translator.mouseDown(.right, at: point(event))) }
    override func rightMouseUp(with event: NSEvent) { hand(translator.mouseUp(.right, at: point(event))) }

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
