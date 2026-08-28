import AppKit
import AVFoundation
import CoreMedia
import SwiftUI

/// Delivers compressed video frames directly to AppKit display layers without
/// publishing every frame through SwiftUI's state system.
final class VideoSampleBufferRelay: @unchecked Sendable {
    private final class WeakLayer {
        weak var value: AVSampleBufferDisplayLayer?

        init(_ value: AVSampleBufferDisplayLayer) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private var layers: [UUID: WeakLayer] = [:]

    @discardableResult
    func attach(_ layer: AVSampleBufferDisplayLayer) -> UUID {
        let token = UUID()
        lock.withLock { layers[token] = WeakLayer(layer) }
        return token
    }

    func detach(_ token: UUID?) {
        guard let token else { return }
        _ = lock.withLock { layers.removeValue(forKey: token) }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let activeLayers: [AVSampleBufferDisplayLayer] = lock.withLock {
            layers = layers.filter { $0.value.value != nil }
            return layers.values.compactMap(\.value)
        }
        guard !activeLayers.isEmpty else { return }

        DispatchQueue.main.async {
            for layer in activeLayers {
                if layer.status == .failed { layer.flush() }
                layer.enqueue(sampleBuffer)
            }
        }
    }

    func flush() {
        let activeLayers: [AVSampleBufferDisplayLayer] = lock.withLock {
            layers.values.compactMap(\.value)
        }
        DispatchQueue.main.async {
            for layer in activeLayers { layer.flushAndRemoveImage() }
        }
    }
}

struct LiveVideoPreview: NSViewRepresentable {
    let relay: VideoSampleBufferRelay

    func makeNSView(context: Context) -> LiveVideoPreviewView {
        let view = LiveVideoPreviewView()
        view.connect(to: relay)
        return view
    }

    func updateNSView(_ nsView: LiveVideoPreviewView, context: Context) {
        nsView.connect(to: relay)
    }

    static func dismantleNSView(_ nsView: LiveVideoPreviewView, coordinator: ()) {
        nsView.disconnect()
    }
}

final class LiveVideoPreviewView: NSView {
    private let videoLayer = AVSampleBufferDisplayLayer()
    private weak var relay: VideoSampleBufferRelay?
    private var relayToken: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        videoLayer.videoGravity = .resizeAspect
        // Keep the layer transparent until the stream delivers its first frame.
        // The SwiftUI view underneath supplies an immediate screenshot fallback.
        videoLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(videoLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        videoLayer.frame = bounds
    }

    func connect(to nextRelay: VideoSampleBufferRelay) {
        guard relay !== nextRelay else { return }
        disconnect()
        relay = nextRelay
        relayToken = nextRelay.attach(videoLayer)
    }

    func disconnect() {
        relay?.detach(relayToken)
        relayToken = nil
        relay = nil
        videoLayer.flushAndRemoveImage()
    }
}

struct AnnexBNALParser {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        return extractCompleteNALUnits(flush: false)
    }

    mutating func finish() -> [Data] {
        extractCompleteNALUnits(flush: true)
    }

    private mutating func extractCompleteNALUnits(flush: Bool) -> [Data] {
        var units: [Data] = []
        while let first = startCode(in: buffer, from: 0) {
            if first.offset > 0 {
                buffer.removeSubrange(0..<first.offset)
                continue
            }

            if let next = startCode(in: buffer, from: first.length) {
                let unit = buffer.subdata(in: first.length..<next.offset)
                if !unit.isEmpty { units.append(unit) }
                buffer.removeSubrange(0..<next.offset)
                continue
            }

            if flush {
                let unit = buffer.subdata(in: first.length..<buffer.count)
                if !unit.isEmpty { units.append(unit) }
                buffer.removeAll(keepingCapacity: true)
            }
            break
        }

        if flush { buffer.removeAll(keepingCapacity: true) }
        return units
    }

    private func startCode(in data: Data, from offset: Int) -> (offset: Int, length: Int)? {
        guard data.count >= 3, offset <= data.count - 3 else { return nil }
        var index = offset
        while index <= data.count - 3 {
            if data[index] == 0, data[index + 1] == 0 {
                if data[index + 2] == 1 { return (index, 3) }
                if index + 3 < data.count, data[index + 2] == 0, data[index + 3] == 1 {
                    return (index, 4)
                }
            }
            index += 1
        }
        return nil
    }
}

private final class H264SampleBufferFactory {
    private var sequenceParameterSet: Data?
    private var pictureParameterSet: Data?
    private var formatDescription: CMVideoFormatDescription?

    func makeSampleBuffer(from nalUnit: Data) -> (CMSampleBuffer, CGSize)? {
        guard let firstByte = nalUnit.first else { return nil }
        switch firstByte & 0x1F {
        case 7:
            sequenceParameterSet = nalUnit
            rebuildFormatDescription()
            return nil
        case 8:
            pictureParameterSet = nalUnit
            rebuildFormatDescription()
            return nil
        case 1, 5:
            break
        default:
            return nil
        }

        guard let formatDescription else { return nil }
        var packet = Data(count: 4)
        var length = UInt32(nalUnit.count).bigEndian
        withUnsafeBytes(of: &length) { packet.replaceSubrange(0..<4, with: $0) }
        packet.append(nalUnit)

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: packet.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: packet.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = packet.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: packet.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = packet.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        // DisplayImmediately is a per-sample attachment. A generic
        // `CMSetAttachment` lands at the buffer level and the video renderer can
        // still wait for timestamps, which turns a live feed into a long queue.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return (sampleBuffer, CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
    }

    private func rebuildFormatDescription() {
        guard let sequenceParameterSet, let pictureParameterSet else { return }
        var description: CMFormatDescription?
        sequenceParameterSet.withUnsafeBytes { sequenceBytes in
            pictureParameterSet.withUnsafeBytes { pictureBytes in
                let pointers = [
                    sequenceBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    pictureBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                let sizes = [sequenceParameterSet.count, pictureParameterSet.count]
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        formatDescription = description
    }
}

final class AndroidH264PreviewStream: @unchecked Sendable {
    private let adbPath: String
    private let deviceID: String
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(adbPath: String, deviceID: String) {
        self.adbPath = adbPath
        self.deviceID = deviceID
    }

    func run(
        relay: VideoSampleBufferRelay,
        onReady: @escaping @Sendable (CGSize) -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try self.runBlocking(relay: relay, onReady: onReady)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func runBlocking(
        relay: VideoSampleBufferRelay,
        onReady: @escaping @Sendable (CGSize) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = [
            "-s", deviceID,
            "exec-out", "screenrecord",
            "--output-format=h264",
            "--bit-rate", "8M",
            "--time-limit", "0",
            "-",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let shouldLaunch = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            self.process = process
            return true
        }
        guard shouldLaunch else {
            relay.flush()
            return
        }
        defer {
            lock.withLock { self.process = nil }
            relay.flush()
        }

        do {
            try process.run()
        } catch {
            throw CaptureError.other("Could not start Android live preview: \(error.localizedDescription)")
        }
        if isCancelled, process.isRunning { process.terminate() }
        Log.shared.log("android: H.264 live stream started \(deviceID)")

        var errorData = Data()
        let errorDrain = DispatchGroup()
        errorDrain.enter()
        DispatchQueue.global().async {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            errorDrain.leave()
        }

        var parser = AnnexBNALParser()
        let factory = H264SampleBufferFactory()
        var sentReady = false
        while !isCancelled {
            guard let chunk = try outputPipe.fileHandleForReading.read(upToCount: 256 * 1_024),
                  !chunk.isEmpty else { break }
            for nalUnit in parser.append(chunk) {
                guard let (sampleBuffer, size) = factory.makeSampleBuffer(from: nalUnit) else { continue }
                if !sentReady {
                    sentReady = true
                    onReady(size)
                }
                relay.enqueue(sampleBuffer)
            }
        }

        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        _ = errorDrain.wait(timeout: .now() + 2)
        guard isCancelled else {
            let message = String(data: errorData, encoding: .utf8)?
                .split(whereSeparator: \.isNewline).first.map(String.init)
            throw CaptureError.other(message ?? "Android live preview stopped.")
        }
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    private func cancel() {
        lock.withLock {
            cancelled = true
            if process?.isRunning == true { process?.terminate() }
        }
    }
}
