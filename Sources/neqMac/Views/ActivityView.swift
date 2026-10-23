import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaneHeader(
                    title: "Activity",
                    blurb: "A local timeline of device and policy changes, newest first. Nothing leaves your Mac."
                )

                if model.events.isEmpty {
                    ContentUnavailableView(
                        "No activity yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Connect or disconnect a device, or change your priority order, and it will be logged here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.events.enumerated()), id: \.element.id) { index, event in
                            EventRow(
                                event: event,
                                isFirst: index == 0,
                                isLast: index == model.events.count - 1
                            )
                        }
                    }
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                    )
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct EventRow: View {
    let event: RoutingEvent
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Same rail motif, used here as a timeline spine.
            VStack(spacing: 3) {
                RailStroke(isLive: false, tint: .secondary)
                    .frame(height: 6)
                    .opacity(isFirst ? 0 : 1)

                Image(systemName: event.level.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(event.level.color)

                RailStroke(isLive: false, tint: .secondary)
                    .frame(height: 24)
                    .opacity(isLast ? 0 : 1)
            }
            .frame(width: 18)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.message)
                    .fixedSize(horizontal: false, vertical: true)
                Text(event.date, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 5)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(event.level.spokenLabel): \(event.message), \(event.date.formatted(date: .omitted, time: .standard))"
        )
    }
}

private extension RoutingEvent.Level {
    var icon: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        }
    }

    var spokenLabel: String {
        switch self {
        case .info: "Note"
        case .success: "Done"
        case .warning: "Warning"
        }
    }
}
