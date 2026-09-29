import AppKit

/// Puts a captured PNG on the system clipboard so it can be pasted straight into
/// chats, docs, image editors, etc. Offers both PNG and TIFF representations for
/// maximum app compatibility.
enum Pasteboard {
    /// The provider for the item currently on the clipboard. Held here so it
    /// outlives `copyPNG`; released once the clipboard no longer needs it.
    @MainActor private static var tiffProvider: TIFFProvider?

    @MainActor
    static func copyPNG(_ data: Data, to pasteboard: NSPasteboard = .general) {
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        // Most apps take the PNG. Encoding a full-resolution TIFF up front cost
        // 13–45 ms per capture, so it is only built if a paste asks for it.
        let provider = TIFFProvider(png: data)
        item.setDataProvider(provider, forTypes: [.tiff])
        tiffProvider = provider
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    @MainActor
    fileprivate static func release(_ provider: TIFFProvider) {
        if tiffProvider === provider { tiffProvider = nil }
    }
}

private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private let png: Data

    init(png: Data) {
        self.png = png
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .tiff, let tiff = NSImage(data: png)?.tiffRepresentation else { return }
        item.setData(tiff, forType: .tiff)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        MainActor.assumeIsolated { Pasteboard.release(self) }
    }
}
