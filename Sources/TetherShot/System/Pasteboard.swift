import AppKit

/// Puts a captured PNG on the system clipboard so it can be pasted straight into
/// chats, docs, image editors, etc. Writes both PNG and TIFF representations for
/// maximum app compatibility.
enum Pasteboard {
    static func copyPNG(_ data: Data) {
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}
