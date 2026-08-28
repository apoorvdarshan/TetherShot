import Foundation

enum PreviewActivityPolicy {
    static func windowAllowsPreview(
        isVisible: Bool,
        isMiniaturized: Bool,
        occlusionIsVisible: Bool,
        appIsHidden: Bool
    ) -> Bool {
        isVisible && !isMiniaturized && occlusionIsVisible && !appIsHidden
    }

    static func shouldRun(
        previewsEnabled: Bool,
        windowIsVisible: Bool,
        previewPageIsVisible: Bool
    ) -> Bool {
        previewsEnabled && windowIsVisible && previewPageIsVisible
    }
}
