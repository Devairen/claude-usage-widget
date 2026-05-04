import SwiftUI

struct ModelRowView: View {
    let model: ModelUsage

    var body: some View {
        HStack(spacing: 8) {
            Text(model.name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            // Inline progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.06))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.swiftUIColor(for: model.percentage))
                        .frame(width: max(geo.size.width * min(model.percentage / 100, 1), 2))
                        .animation(.easeInOut(duration: 0.3), value: model.percentage)
                }
            }
            .frame(height: 6)

            Text("\(Int(model.percentage))%")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }
}
