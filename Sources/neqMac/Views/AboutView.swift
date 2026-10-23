import SwiftUI

struct AboutView: View {
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    ChainMark()
                        .frame(width: 72, height: 84)
                        .accessibilityHidden(true)

                    VStack(spacing: 6) {
                        Text("neqMac")
                            .font(.system(size: 28, weight: .bold))
                        Text("A quieter, more predictable audio device guardian for macOS.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 6) {
                        StatusBadge(text: "Proof of concept", systemImage: "hammer.fill")
                        StatusBadge(text: "Routing only", systemImage: "arrow.triangle.branch")
                    }

                    Text("This milestone covers ordering, pinning and excluding audio inputs and outputs. EQ profiles are not part of this build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(geometry.size.height - 80, 0))
                .padding(40)
            }
            .defaultScrollAnchor(.center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The app mark: the signal chain, solid until it lands, dashed after.
private struct ChainMark: View {
    var body: some View {
        VStack(spacing: 0) {
            RailStroke(isLive: true, tint: .accentColor)
                .frame(height: 22)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            RailStroke(isLive: false, tint: .accentColor)
                .frame(height: 22)
            Image(systemName: "circle.dashed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.5))
        }
    }
}
