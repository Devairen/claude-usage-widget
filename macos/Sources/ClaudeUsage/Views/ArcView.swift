import SwiftUI

struct ArcView: View {
    let percentage: Double
    var size: CGFloat = 36
    var lineWidth: CGFloat = 4
    var showLabel: Bool = true

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)

            // Progress
            Circle()
                .trim(from: 0, to: min(percentage / 100, 1))
                .stroke(
                    Theme.swiftUIColor(for: percentage),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: percentage)

            // Center label
            if showLabel && size >= 32 {
                Text("\(Int(percentage))")
                    .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
    }
}
