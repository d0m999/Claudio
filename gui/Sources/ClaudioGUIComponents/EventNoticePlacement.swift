import CoreGraphics
import Foundation

/// Pure geometry for the top-centre capsule. Kept in the shared component target so the
/// window controller and the presentation harness compute identical results, including the
/// notch/menu-bar safe-area contract (SPEC 原生呈现: 可见安全区与刘海 safeAreaInsets 交集后
/// 向下 12pt，约 440pt 宽，两侧至少 16pt).
public enum EventNoticePlacement {
    public static let preferredWidth: CGFloat = 440
    public static let minimumWidth: CGFloat = 280
    public static let horizontalMargin: CGFloat = 16
    public static let topOffset: CGFloat = 12

    /// Extra inset the notch (or a hidden menu bar) carves into `visibleFrame` from the top.
    /// `NSScreen.safeAreaInsets.top` covers the whole camera housing; the part already excluded
    /// by the menu bar (`frame.maxY - visibleFrame.maxY`) must not be applied twice.
    public static func effectiveTopSafeInset(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat
    ) -> CGFloat {
        let menuBarAllowance = max(0, screenFrame.maxY - visibleFrame.maxY)
        return max(0, safeAreaTop - menuBarAllowance)
    }

    /// Y of the window's bottom-left origin so its top edge sits `topOffset` below the
    /// effective safe area.
    public static func topAnchorY(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        height: CGFloat
    ) -> CGFloat {
        let inset = effectiveTopSafeInset(
            screenFrame: screenFrame, visibleFrame: visibleFrame, safeAreaTop: safeAreaTop)
        let y = visibleFrame.maxY - inset - topOffset - height
        return max(visibleFrame.minY + horizontalMargin, y)
    }

    public static func clampedWidth(visibleFrame: CGRect) -> CGFloat {
        min(preferredWidth, max(minimumWidth, visibleFrame.width - 2 * horizontalMargin))
    }

    public static func clampedX(visibleFrame: CGRect, width: CGFloat) -> CGFloat {
        let minimumX = visibleFrame.minX + horizontalMargin
        let maximumX = max(minimumX, visibleFrame.maxX - width - horizontalMargin)
        return min(max(visibleFrame.midX - width / 2, minimumX), maximumX)
    }
}
