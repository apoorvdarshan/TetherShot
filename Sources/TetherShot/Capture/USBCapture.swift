import AVFoundation
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
        return found.map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName, connection: .usb) }
    }

    func capture(deviceID: String) async throws -> Data {
        guard let device = discoverySession().devices.first(where: { $0.uniqueID == deviceID })
            ?? AVCaptureDevice(uniqueID: deviceID) else {
            throw CaptureError.noDevice
        }

        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw CaptureError.permissionDenied
        }

        return try await FrameGrabber().grab(device: device)
    }
}

/// Spins up a one-shot capture session, grabs the first delivered frame, and
/// tears everything down. Lives for exactly one screenshot.
///
/// `@unchecked Sendable`: all mutable state (`continuation`, `finished`) is
/// touched only inside `finish`, which funnels every access onto `queue`.
private final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.apoorvdarshan.tethershot.capture")
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false

    func grab(device: AVCaptureDevice) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            do {
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    finish(.failure(CaptureError.other("Cannot read this device.")))
                    return
                }
                session.addInput(input)
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
                session.commitConfiguration()
                session.startRunning()

                queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                    self?.finish(.failure(CaptureError.timeout))
                }
            } catch {
                finish(.failure(error))
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let png = Self.png(from: sampleBuffer) else { return }
        finish(.success(png))
    }

    /// Resolves the continuation exactly once and stops the session.
    private func finish(_ result: Result<Data, Error>) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.session.stopRunning()
            let continuation = self.continuation
            self.continuation = nil
            switch result {
            case .success(let data): continuation?.resume(returning: data)
            case .failure(let error): continuation?.resume(throwing: error)
            }
        }
    }

    private static func png(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvImageBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
