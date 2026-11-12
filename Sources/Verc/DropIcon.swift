import SwiftUI

struct DropIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var circleOffset = 32.0
    @State private var dashOffset = 6.0
    @State private var rotation = -180.0
    @State private var showDashes = false
    @State private var stemOffset = 10.0
    @State private var arrowOffset = 8.0

    var body: some View {
        Rectangle().fill(.foreground)
            .frame(width: 24, height: 24)
            .mask {
                ZStack {
                    Path {
                        $0.move(to: CGPoint(x: 12, y: 21))
                        $0.addCurve(to: CGPoint(x: 3, y: 12), control1: CGPoint(x: 7.03, y: 21), control2: CGPoint(x: 3, y: 16.97))
                        $0.addCurve(to: CGPoint(x: 12, y: 3), control1: CGPoint(x: 3, y: 7.03), control2: CGPoint(x: 7.03, y: 3))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [32], dashPhase: circleOffset))
                    Path {
                        $0.move(to: CGPoint(x: 12, y: 3))
                        $0.addCurve(to: CGPoint(x: 21, y: 12), control1: CGPoint(x: 16.97, y: 3), control2: CGPoint(x: 21, y: 7.03))
                        $0.addCurve(to: CGPoint(x: 12, y: 21), control1: CGPoint(x: 21, y: 16.97), control2: CGPoint(x: 16.97, y: 21))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [2, 4], dashPhase: dashOffset))
                    .rotationEffect(.degrees(rotation))
                    .opacity(showDashes ? 1 : 0)
                    Path {
                        $0.move(to: CGPoint(x: 12, y: 8))
                        $0.addLine(to: CGPoint(x: 12, y: 15.5))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [10], dashPhase: stemOffset))
                    Path {
                        $0.move(to: CGPoint(x: 12, y: 15.5))
                        $0.addLine(to: CGPoint(x: 15.5, y: 12))
                        $0.move(to: CGPoint(x: 12, y: 15.5))
                        $0.addLine(to: CGPoint(x: 8.5, y: 12))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [8], dashPhase: arrowOffset))
                }
                .foregroundStyle(.white)
            }
            .scaleEffect(32.0 / 24).frame(width: 32, height: 32)
            .accessibilityHidden(true).allowsHitTesting(false)
            .task(id: reduceMotion) {
                withAnimation(.linear(duration: 0)) {
                    circleOffset = reduceMotion ? 0 : 32
                    dashOffset = reduceMotion ? 0 : 6
                    rotation = reduceMotion ? 0 : -180
                    showDashes = reduceMotion
                    stemOffset = reduceMotion ? 0 : 10
                    arrowOffset = reduceMotion ? 0 : 8
                }
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.6)) { circleOffset = 0 }
                do {
                    try await Task.sleep(for: .milliseconds(450))
                    showDashes = true
                    withAnimation(.linear(duration: 0.6)) { rotation = 0 }
                    try await Task.sleep(for: .milliseconds(400))
                    withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) { dashOffset = 0 }
                    withAnimation(.linear(duration: 0.2)) { stemOffset = 0 }
                    try await Task.sleep(for: .milliseconds(200))
                    withAnimation(.linear(duration: 0.2)) { arrowOffset = 0 }
                } catch {}
            }
    }
}
