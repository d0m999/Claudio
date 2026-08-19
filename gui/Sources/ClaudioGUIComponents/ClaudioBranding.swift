import SwiftUI

/// claudi0 的统一横向字标：产品名保持完整可读，末尾 `0` 使用 Orbit Zero 的
/// 双环、斜轨与信号点。面板与首次启动页只渲染这一份组件，避免品牌字形再次漂移。
public struct ClaudioOrbitWordmark: View {
    public let height: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(height: CGFloat = 20) {
        self.height = height
    }

    public var body: some View {
        HStack(alignment: .center, spacing: -height * 0.22) {
            Text("claudi")
                .font(.system(size: height * 0.94, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.text(colorScheme))
                .fixedSize()

            ClaudioOrbitZeroMark(size: height)
        }
        .frame(height: height)
        .fixedSize()
        // 轨道、光晕与信号点是一个视觉字形，不应在 VoiceOver 中拆成多个装饰节点。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("claudi0")
    }
}

/// Orbit Zero 的可缩放 SwiftUI 几何。窗口字标使用完整版本；16pt 菜单栏图标在
/// `MenuBarIcon` 中使用同一母题的减法版本，避免细节在系统状态栏压力下糊成一团。
public struct ClaudioOrbitZeroMark: View {
    public let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(size: CGFloat = 20) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            // 截图中 0 背后的两层暖色光晕。
            Ellipse()
                .stroke(ClaudioTheme.clay(colorScheme).opacity(0.10), lineWidth: size * 0.13)
                .frame(width: size * 0.82, height: size * 0.94)

            Ellipse()
                .stroke(ClaudioTheme.clay(colorScheme), lineWidth: max(1.4, size * 0.10))
                .frame(width: size * 0.56, height: size * 0.88)

            // 斜轨故意穿过字形，静态时也保留“正在运行”的方向感。
            Ellipse()
                .stroke(
                    ClaudioTheme.text(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.52),
                    lineWidth: max(0.75, size * 0.035))
                .frame(width: size * 1.48, height: size * 0.50)
                .rotationEffect(.degrees(-16))

            Circle()
                .fill(ClaudioTheme.clay(colorScheme))
                .frame(width: max(2, size * 0.12), height: max(2, size * 0.12))
                .offset(x: size * 0.56, y: -size * 0.34)
        }
        .offset(x: -size * 0.22)
        .frame(width: size * 1.36, height: size)
        .accessibilityHidden(true)
    }
}
