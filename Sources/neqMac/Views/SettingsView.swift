import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: Pane = .routing

    enum Pane: String, CaseIterable, Identifiable {
        case routing = "Routing"
        case activity = "Activity"
        case about = "About"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .routing: "arrow.triangle.branch"
            case .activity: "clock.arrow.circlepath"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(Pane.allCases) { pane in
                    SidebarButton(
                        pane: pane,
                        isSelected: selection == pane
                    ) {
                        selection = pane
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 168)
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch selection {
                case .routing: RoutingSettingsView()
                case .activity: ActivityView()
                case .about: AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 600)
    }
}

private struct SidebarButton: View {
    let pane: SettingsView.Pane
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 20)

                Text(pane.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane.rawValue)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

struct PaneHeader: View {
    let title: String
    let blurb: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
            Text(blurb)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityAddTraits(.isHeader)
    }
}
