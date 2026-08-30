import AppKit
import ImageIO

enum LivePreviewPhase: Equatable {
    case idle
    case loading
    case live
    case paused
    case failed(String)
}

enum LivePreviewRefreshPolicy {
    static func intervalNanoseconds(for connection: ConnectionKind) -> UInt64 {
        switch connection {
        case .usb:
            return 100_000_000
        case .wireless:
            return 400_000_000
        case .androidUSB:
            return 250_000_000
        case .androidWireless:
            return 400_000_000
        }
    }

    static func maximumFrameAge(for connection: ConnectionKind) -> TimeInterval {
        switch connection {
        case .usb:
            return 2
        case .wireless:
            return 3
        case .androidUSB, .androidWireless:
            return 2
        }
    }
}

enum LivePreviewAspectRatio {
    /// A modern portrait phone silhouette used until the first frame arrives.
    static let portraitFallback: CGFloat = 9.0 / 19.5

    static func value(width: CGFloat, height: CGFloat) -> CGFloat {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return portraitFallback
        }
        return min(max(width / height, 0.25), 4)
    }
}

/// Per-device observable state keeps frequent preview updates scoped to the
/// corresponding card instead of invalidating the entire app window.
@MainActor
final class DevicePreviewState: ObservableObject, Identifiable {
    let id: String
    let videoRelay = VideoSampleBufferRelay()

    @Published private(set) var image: NSImage?
    @Published private(set) var phase: LivePreviewPhase = .idle
    @Published private(set) var videoAspectRatio: CGFloat?

    private(set) var latestPNG: Data?
    private(set) var updatedAt: Date?
    private var updateGeneration: UInt64 = 0

    init(id: String) {
        self.id = id
    }

    var displayAspectRatio: CGFloat {
        if let videoAspectRatio { return videoAspectRatio }
        guard let image else { return LivePreviewAspectRatio.portraitFallback }
        return LivePreviewAspectRatio.value(width: image.size.width, height: image.size.height)
    }

    func markLoading() {
        // Keep an already-rendering preview live while its next frame is being
        // fetched. USB uses repeated one-shot captures, so demoting the phase
        // here would make the LIVE badge flicker off for most of every cycle.
        guard phase != .loading, phase != .live else { return }
        phase = .loading
    }

    func update(png: Data, reusableForCapture: Bool = true) async {
        updateGeneration &+= 1
        let generation = updateGeneration
        let thumbnail = await Task.detached(priority: .userInitiated) {
            LivePreviewImage.thumbnail(from: png)
        }.value
        guard phase != .paused, generation == updateGeneration else { return }
        guard let thumbnail else {
            fail("Preview could not be decoded")
            return
        }
        if reusableForCapture {
            latestPNG = png
            updatedAt = Date()
        } else {
            // Wi-Fi live previews are intentionally resized JPEGs. A Capture
            // action must still request the original full-resolution PNG.
            latestPNG = nil
            updatedAt = nil
        }
        image = thumbnail
        if phase != .live { phase = .live }
    }

    func markVideoLive(size: CGSize) {
        let ratio = LivePreviewAspectRatio.value(width: size.width, height: size.height)
        if videoAspectRatio != ratio { videoAspectRatio = ratio }
        if phase != .live { phase = .live }
    }

    func pause() {
        guard phase != .paused else { return }
        updateGeneration &+= 1
        videoRelay.flush()
        phase = .paused
    }

    func fail(_ message: String) {
        videoRelay.flush()
        let next = LivePreviewPhase.failed(message)
        guard phase != next else { return }
        phase = next
    }

    func recentPNG(maximumAge: TimeInterval, now: Date = Date()) -> Data? {
        guard let latestPNG, let updatedAt,
              now.timeIntervalSince(updatedAt) <= maximumAge else { return nil }
        return latestPNG
    }
}

private enum LivePreviewImage {
    /// Decode a small display image. Capture-quality PNG data is retained
    /// separately only for transports whose preview frames are full resolution.
    static func thumbnail(from data: Data, maximumPixelSize: Int = 1_200) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: .zero)
    }
}
