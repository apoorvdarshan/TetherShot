@preconcurrency import AVFoundation
import CoreMediaIO
import AppKit

/// Captures the screen of a USB-connected, trusted iPhone.
///
/// macOS exposes a tethered iPhone's *screen* as an `AVCaptureDevice` of media
/// type `.muxed` — the same source QuickTime/OBS use for "iPhone as screen".
/// It only appears after we flip the CoreMediaIO opt-in flag below.
final class USBCapture: NSObject, CaptureBackend {

    override init() {
        super.init()
        Self.enableScreenCaptureDevices()
    }

    /// Opt in to seeing iOS device *screens* (not just cameras) as capture devices.
    /// Must run before discovery or the muxed iPhone device stays hidden.
    private static func enableScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &allow
        )
    }

    private func discoverySession() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,        // .muxed = the iPhone screen; .video would be the camera
            position: .unspecified
        )
    }

    func discoverDevices() -> [CaptureDevice] {
        var found = discoverySession().devices
        if let fallback = AVCaptureDevice.default(for: .muxed),
           !found.contains(fallback) {
            found.append(fallback)
        }
        return found.map {
            CaptureDevice(
                id: DeviceIdentity.iOS(rawID: $0.uniqueID),
                captureID: $0.uniqueID,
                name: $0.localizedName,
                connection: .usb
            )
        }
    }

    func capture(deviceID: String) async throws -> Data {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else {
            Log.shared.log("capture: camera not authorized (status \(status.rawValue))")
            throw CaptureError.permissionDenied
        }
        guard let device = discoverySession().devices.first(where: { $0.uniqueID == deviceID })
            ?? AVCaptureDevice(uniqueID: deviceID) else {
            Log.shared.log("capture: device \(deviceID) not found")
            throw CaptureError.noDevice
        }
        Log.shared.log("capture: device found '\(device.localizedName)' connected=\(device.isConnected)")
        return try await FrameGrabber().grab(device: device)
    }

    /// Keeps one native USB session open for the lifetime of the visible live
    /// preview. Repeatedly opening a muxed iPhone input also reconnects its
    /// audio channel, which can trigger accessory/headphones prompts.
    func streamPreview(
        deviceID: String,
        onFrame: @escaping @Sendable (Data) -> Void
    ) async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else { throw CaptureError.permissionDenied }
        guard let device = discoverySession().devices.first(where: { $0.uniqueID == deviceID })
            ?? AVCaptureDevice(uniqueID: deviceID) else {
            throw CaptureError.noDevice
        }
        try await USBPreviewStream(device: device, onFrame: onFrame).run()
    }
}

/// A persistent video-only session for native USB live preview.
private final class USBPreviewStream: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let device: AVCaptureDevice
    private let onFrame: @Sendable (Data) -> Void
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let context = CIContext()
    private let sessionQueue = DispatchQueue(label: "com.apoorvdarshan.tethershot.usb-preview.session")
    private let delegateQueue = DispatchQueue(label: "com.apoorvdarshan.tethershot.usb-preview.frames")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private var lastFrameTime: TimeInterval = 0

    init(device: AVCaptureDevice, onFrame: @escaping @Sendable (Data) -> Void) {
        self.device = device
        self.onFrame = onFrame
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()

                sessionQueue.async { [weak self] in self?.start() }
            }
        } onCancel: { [weak self] in
            self?.finish(.success(()))
        }
    }

    private func start() {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.sessionPreset = .high
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: delegateQueue)
            try USBSessionConfigurator.configureVideoOnly(
                session: session,
                input: input,
                output: output
            )
            guard !isFinished else { return }
            session.startRunning()
            Log.shared.log("usb: persistent preview started '\(device.localizedName)'")
        } catch {
            finish(.failure(error))
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isFinished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrameTime >= 0.10 else { return }
        lastFrameTime = now
        guard let png = USBFrameEncoder.png(from: sampleBuffer, context: context) else { return }
        onFrame(png)
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        output.setSampleBufferDelegate(nil, queue: nil)
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
            Log.shared.log("usb: persistent preview stopped")
        }
        continuation?.resume(with: result)
    }
}

/// Spins up a one-shot capture session, grabs the first delivered frame, and
/// tears everything down. Lives for exactly one screenshot.
///
/// All AVFoundation work runs on a dedicated dispatch queue (never the Swift
/// concurrency cooperative pool, where `startRunning()` can deadlock). A timeout
/// is armed on an independent queue so the call can never hang forever.
///
/// `@unchecked Sendable`: `continuation`/`finished` are guarded by `lock`.
private final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.apoorvdarshan.tethershot.session")
    private let delegateQueue = DispatchQueue(label: "com.apoorvdarshan.tethershot.frames")
    private let context = CIContext()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false

    func grab(device: AVCaptureDevice) async throws -> Data {
        Log.shared.log("grab: begin '\(device.localizedName)'")
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            // Independent timeout — cannot be blocked by session work.
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.finish(.failure(CaptureError.timeout))
            }

            sessionQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    Log.shared.log("grab: input created")
                    self.output.alwaysDiscardsLateVideoFrames = true
                    self.output.setSampleBufferDelegate(self, queue: self.delegateQueue)
                    try USBSessionConfigurator.configureVideoOnly(
                        session: self.session,
                        input: input,
                        output: self.output
                    )
                    Log.shared.log("grab: video-only output added")
                    Log.shared.log("grab: committed, calling startRunning")
                    self.session.startRunning()
                    Log.shared.log("grab: startRunning returned, isRunning=\(self.session.isRunning)")
                } catch {
                    Log.shared.log("grab: setup error \(error.localizedDescription)")
                    self.finish(.failure(error))
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let png = USBFrameEncoder.png(from: sampleBuffer, context: context) else {
            Log.shared.log("captureOutput: frame had no image buffer (awaiting next)")
            return
        }
        Log.shared.log("captureOutput: encoded \(png.count) bytes")
        finish(.success(png))
    }

    /// Resolves the continuation exactly once and stops the session.
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        let sessionRef = session
        sessionQueue.async { sessionRef.stopRunning() }

        switch result {
        case .success(let data):
            Log.shared.log("finish: success (\(data.count) bytes)")
            continuation?.resume(returning: data)
        case .failure(let error):
            Log.shared.log("finish: failure (\(error.localizedDescription))")
            continuation?.resume(throwing: error)
        }
    }

}

private enum USBSessionConfigurator {
    /// A muxed iPhone input advertises video, sound, closed-caption, and
    /// metadata ports. Automatic session connections can activate the sound
    /// endpoint and make iOS ask whether the Mac is a pair of headphones.
    /// Connect only the video port explicitly.
    static func configureVideoOnly(
        session: AVCaptureSession,
        input: AVCaptureDeviceInput,
        output: AVCaptureVideoDataOutput
    ) throws {
        guard let videoPort = input.ports.first(where: { $0.mediaType == .video }) else {
            throw CaptureError.other("The iPhone screen has no video port.")
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CaptureError.other("Cannot read this iPhone screen.")
        }
        session.addInputWithNoConnections(input)
        session.addOutputWithNoConnections(output)

        let videoConnection = AVCaptureConnection(inputPorts: [videoPort], output: output)
        guard session.canAddConnection(videoConnection) else {
            throw CaptureError.other("Cannot connect the iPhone video stream.")
        }
        session.addConnection(videoConnection)
    }
}

private enum USBFrameEncoder {
    static func png(from sampleBuffer: CMSampleBuffer, context: CIContext) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvImageBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
