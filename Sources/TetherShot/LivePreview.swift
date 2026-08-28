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

    @Published private(set) var image: NSImage?
    @Published private(set) var phase: LivePreviewPhase = .idle

    private(set) var latestPNG: Data?
    private(set) var updatedAt: Date?

    init(id: String) {
        self.id = id
    }

    var displayAspectRatio: CGFloat {
        guard let image else { return LivePreviewAspectRatio.portraitFallback }
        return LivePreviewAspectRatio.value(width: image.size.width, height: image.size.height)
    }

    func markLoading() {
        guard image == nil, phase != .loading else { return }
        phase = .loading
    }

    func update(png: Data) {
        guard let thumbnail = LivePreviewImage.thumbnail(from: png) else {
            fail("Preview could not be decoded")
            return
        }
        latestPNG = png
        updatedAt = Date()
        image = thumbnail
        if phase != .live { phase = .live }
    }

    func pause() {
        guard phase != .paused else { return }
        phase = .paused
    }

    func fail(_ message: String) {
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
    /// Decode a small display image while retaining the original PNG bytes for
    /// saving. This avoids keeping several full-resolution decoded frames alive.
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
