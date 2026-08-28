import Foundation

enum LivePreviewLayoutPolicy {
    static let maximumColumnCount = 3
    static let minimumColumnWidth: CGFloat = 360
    static let spacing: CGFloat = 14

    static func columnCount(availableWidth: CGFloat, deviceCount: Int) -> Int {
        guard deviceCount > 1 else { return 1 }
        let fittingColumns = Int((availableWidth + spacing) / (minimumColumnWidth + spacing))
        return min(deviceCount, maximumColumnCount, max(1, fittingColumns))
    }

    static func tileHeight(
        availableHeight: CGFloat,
        deviceCount: Int,
        columnCount: Int
    ) -> CGFloat {
        let rows = max(1, Int(ceil(Double(deviceCount) / Double(max(1, columnCount)))))
        let toolbarAllowance: CGFloat = 42
        let rowSpacing = CGFloat(max(0, rows - 1)) * spacing
        let availableForTiles = availableHeight - toolbarAllowance - spacing - rowSpacing
        return max(360, availableForTiles / CGFloat(rows))
    }
}
