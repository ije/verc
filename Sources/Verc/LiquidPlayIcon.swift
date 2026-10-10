import SwiftUI

struct LiquidPlayIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { context in
            let time = reduceMotion ? 0 : Float(context.date.timeIntervalSince(started)) * 0.45
            let mesh = MeshGradient(width: 4, height: 4, points: [
                [0, 0], [0.33, 0], [0.67, 0], [1, 0],
                [0, 0.33], [0.33 + 0.12 * sin(time), 0.33 + 0.12 * cos(time * 0.8)],
                [0.67 + 0.12 * cos(time * 0.7), 0.33 + 0.12 * sin(time * 0.9)], [1, 0.33],
                [0, 0.67], [0.33 + 0.12 * cos(time * 0.9), 0.67 + 0.12 * sin(time * 0.7)],
                [0.67 + 0.12 * sin(time * 0.8), 0.67 + 0.12 * cos(time)], [1, 0.67],
                [0, 1], [0.33, 1], [0.67, 1], [1, 1]
            ], colors: [
                Color(red: 0.02, green: 0.65, blue: 1), Color(red: 0.10, green: 0.85, blue: 1),
                Color(red: 0, green: 0.83, blue: 0.96), Color(red: 0, green: 0.66, blue: 1),
                Color(red: 0.46, green: 0.66, blue: 1), Color(red: 0.43, green: 0.75, blue: 1),
                Color(red: 0.02, green: 0.73, blue: 1), Color(red: 0, green: 0.63, blue: 0.98),
                Color(red: 0.85, green: 0.61, blue: 1), Color(red: 1, green: 0.64, blue: 0.97),
                Color(red: 0.88, green: 0.73, blue: 1), Color(red: 0.16, green: 0.80, blue: 1),
                Color(red: 1, green: 0.73, blue: 0.96), Color(red: 1, green: 0.83, blue: 0.43),
                Color(red: 1, green: 0.88, blue: 0.60), Color(red: 1, green: 0.76, blue: 0.94)
            ])

            Path {
                $0.move(to: CGPoint(x: 28, y: 14))
                $0.addCurve(to: CGPoint(x: 44, y: 5), control1: CGPoint(x: 28, y: 4), control2: CGPoint(x: 34, y: -1))
                $0.addLine(to: CGPoint(x: 102, y: 39))
                $0.addCurve(to: CGPoint(x: 102, y: 59), control1: CGPoint(x: 113, y: 45), control2: CGPoint(x: 113, y: 53))
                $0.addLine(to: CGPoint(x: 44, y: 93))
                $0.addCurve(to: CGPoint(x: 28, y: 84), control1: CGPoint(x: 34, y: 99), control2: CGPoint(x: 28, y: 94))
                $0.closeSubpath()
            }
            .fill(mesh)
        }
        .frame(width: 112, height: 98)
        .scaleEffect(0.65)
        .frame(width: 112 * 0.65, height: 98 * 0.65)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
