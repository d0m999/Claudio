import Foundation
import SwiftUI

/// Mockup 已修正的 24×24 扬声器几何。静音只降低两道声波的不透明度并叠加斜线；按钮本身的
/// 行为、颜色、焦点和无障碍身份仍由各事件行拥有。
struct EventMuteSpeakerIcon: View {
    let isMuted: Bool
    let color: Color

    var body: some View {
        ZStack {
            SpeakerBodyShape()
                .fill(color)
            SpeakerWaveShape(radius: 4, startX: 16, startY: 9.2, endY: 14.8)
                .stroke(
                    color.opacity(isMuted ? 0.24 : 1),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            SpeakerWaveShape(radius: 8, startX: 18.8, startY: 6.5, endY: 17.5)
                .stroke(
                    color.opacity(isMuted ? 0.24 : 1),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            if isMuted {
                SpeakerSlashShape()
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 24, height: 24)
    }
}

private struct SpeakerBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: speakerPoint(x: 3.5, y: 9, in: rect))
        path.addLine(to: speakerPoint(x: 3.5, y: 15, in: rect))
        path.addLine(to: speakerPoint(x: 7.5, y: 15, in: rect))
        path.addLine(to: speakerPoint(x: 12.5, y: 19, in: rect))
        path.addLine(to: speakerPoint(x: 12.5, y: 5, in: rect))
        path.addLine(to: speakerPoint(x: 7.5, y: 9, in: rect))
        path.closeSubpath()
        return path
    }
}

private struct SpeakerWaveShape: Shape {
    let radius: CGFloat
    let startX: CGFloat
    let startY: CGFloat
    let endY: CGFloat

    func path(in rect: CGRect) -> Path {
        let halfChord = (endY - startY) / 2
        let centerX = startX - sqrt(radius * radius - halfChord * halfChord)
        let angle = asin(halfChord / radius) * 180 / .pi
        let scale = min(rect.width, rect.height) / 24
        var path = Path()
        path.addArc(
            center: speakerPoint(x: centerX, y: (startY + endY) / 2, in: rect),
            radius: radius * scale,
            startAngle: .degrees(-Double(angle)),
            endAngle: .degrees(Double(angle)),
            clockwise: false)
        return path
    }
}

private struct SpeakerSlashShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: speakerPoint(x: 4, y: 4.5, in: rect))
        path.addLine(to: speakerPoint(x: 20, y: 20, in: rect))
        return path
    }
}

private func speakerPoint(x: CGFloat, y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(
        x: rect.minX + x * rect.width / 24,
        y: rect.minY + y * rect.height / 24)
}
