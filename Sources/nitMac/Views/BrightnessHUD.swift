import AppKit
import SwiftUI

/// The on-screen indicator that replaces the one macOS would have drawn.
///
/// Swallowing the brightness keys also swallows the system HUD, so without this
/// the keys work but look broken. A single non-activating panel is reused for
/// every press and simply fades back out.
///
/// It follows the shape Tahoe gives its own volume indicator: a compact panel
/// under the menu bar rather than the large centred square of earlier releases.
@MainActor
final class BrightnessHUD {
    /// The panel's content is driven from this rather than rebuilt, so a held-down
    /// key redraws instead of recreating the window.
    final class Level: ObservableObject {
        @Published var fraction: Double = 0
        @Published var title: String = "Brightness"
    }

    private static let visibleDuration: Duration = .milliseconds(1200)
    private static let fadeDuration: TimeInterval = 0.35
    private static let size = NSSize(width: 292, height: 64)
    private static let cornerRadius: CGFloat = 22
    private static let menuBarGap: CGFloat = 6
    private static let screenEdgeInset: CGFloat = 10

    private let level = Level()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(fraction: Double, title: String, on screen: NSScreen?) {
        let panel = panel ?? makePanel()
        self.panel = panel

        level.fraction = fraction
        level.title = title
        position(panel, on: screen ?? NSScreen.main)
        dismissTask?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled else { return }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 0
            }, completionHandler: nil)

            try? await Task.sleep(for: .milliseconds(Int(Self.fadeDuration * 1000) + 50))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    /// Used when the menu bar panel opens: its slider takes over as the feedback,
    /// and the indicator would otherwise sit on top of it at screen-saver level.
    /// Builds the panel ahead of the first key press. Creating a hosting view and
    /// its glass costs enough that doing it inside the event tap callback risks
    /// tripping the tap's timeout.
    func prepare() {
        if panel == nil { panel = makePanel() }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = OpaqueHostingView(rootView: BrightnessHUDView().environmentObject(level))

        // The glass itself is applied inside the SwiftUI view, which is where
        // the real material lives; AppKit's NSGlassEffectView is a flatter
        // approximation that renders no lensing and no specular edge.
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        return panel
    }

    /// Sits under nitMac's own menu bar item where it can be found, which is where
    /// Tahoe puts the indicator for whichever control the key belongs to.
    private func position(_ panel: NSPanel, on screen: NSScreen?) {
        guard let screen else { return }

        let menuBarBottom = screen.visibleFrame.maxY
        let y = menuBarBottom - Self.menuBarGap - Self.size.height

        let preferredCentre = statusItemFrame(on: screen)?.midX
            ?? screen.frame.maxX - Self.screenEdgeInset - Self.size.width / 2
        let minimum = screen.frame.minX + Self.screenEdgeInset
        let maximum = screen.frame.maxX - Self.screenEdgeInset - Self.size.width
        let x = min(max(preferredCentre - Self.size.width / 2, minimum), maximum)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func statusItemFrame(on screen: NSScreen) -> NSRect? {
        NSApp.windows
            .first { $0.className.contains("StatusBarWindow") && screen.frame.intersects($0.frame) }?
            .frame
    }
}

/// Glass treats its content as vibrant by default, which drags a pure white
/// track down to a mid grey. The indicator Tahoe draws itself is fully white on
/// the same material, so vibrancy is declined here.
private final class OpaqueHostingView<Content: View>: NSHostingView<Content> {
    override var allowsVibrancy: Bool { false }
}

struct BrightnessHUDView: View {
    @EnvironmentObject private var level: BrightnessHUD.Level
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// `Color.primary` is `labelColor`, which is white at 85% in dark mode. The
    /// system indicator draws at full strength, so the ink is taken directly.
    private var ink: Color { colorScheme == .dark ? .white : .black }

    /// Measured off Tahoe's own volume indicator and the Control Center Display
    /// card, both captured at 2x and halved.
    private enum Metrics {
        static let horizontalInset: CGFloat = 15
        static let titleSize: CGFloat = 13
        static let titleInset: CGFloat = 3      // the title sits inboard of the glyphs
        static let topPadding: CGFloat = 11
        static let rowSpacing: CGFloat = 6
        static let glyphSize: CGFloat = 15.5
        static let glyphGap: CGFloat = 6
        static let trackHeight: CGFloat = 4
        static let cornerRadius: CGFloat = 22
        /// The system indicator carries a specular edge in both modes, and
        /// `glassEffect` does not draw one, so it is drawn here. Measured off the
        /// system indicator: 152 over an interior of 50 with glass, 130 over 34
        /// with transparency reduced. 0.75pt reproduces its two-pixel falloff.
        static let rimOpacityGlass: Double = 0.50
        static let rimOpacityFlat: Double = 0.43
        static let rimWidth: CGFloat = 0.75
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            Text(level.title)
                .font(.system(size: Metrics.titleSize, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(1)
                .padding(.leading, Metrics.titleInset)

            HStack(spacing: Metrics.glyphGap) {
                Image(systemName: "sun.min.fill")
                BrightnessTrack(fraction: level.fraction, ink: ink)
                    .frame(height: Metrics.trackHeight)
                Image(systemName: "sun.max.fill")
            }
            .font(.system(size: Metrics.glyphSize))
            .foregroundStyle(ink)
        }
        .padding(.horizontal, Metrics.horizontalInset)
        .padding(.top, Metrics.topPadding)
        .frame(width: 292, height: 64, alignment: .top)
        .hudGlass(cornerRadius: Metrics.cornerRadius)
        // Reduce Transparency flattens every material to an opaque fill, which
        // costs the panel the edge that separates it from the desktop. The system
        // indicator carries a slightly softer edge in that case.
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(
                    ink.opacity(reduceTransparency ? Metrics.rimOpacityFlat : Metrics.rimOpacityGlass),
                    lineWidth: Metrics.rimWidth
                )
        }
        .accessibilityElement()
        .accessibilityLabel(level.title)
        .accessibilityValue("\(Int((level.fraction * 100).rounded())) percent")
    }
}

/// A plain filled capsule. Tahoe draws no tick marks along it, whatever a
/// downscaled screenshot appears to show.
private struct BrightnessTrack: View {
    let fraction: Double
    let ink: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ink.opacity(0.16))
                Capsule()
                    .fill(ink)
                    .frame(width: max(geometry.size.height, geometry.size.width * fraction))
            }
            .animation(.easeOut(duration: 0.14), value: fraction)
        }
    }
}


/// Appearance › Liquid Glass offers Regular and Clear, and the system indicator
/// follows it. `glassEffect` does not: `.regular` renders identically whichever
/// is chosen, so the choice has to be made here.
///
/// The setting is written to `NSGlassDiffusionSetting` in the global domain, and
/// is absent until it is changed from the default, so anything but a stored 0 is
/// treated as Regular.
enum GlassDiffusion {
    static var prefersClear: Bool {
        guard let setting = UserDefaults.standard.object(forKey: "NSGlassDiffusionSetting") as? Int else {
            return false
        }
        return setting == 0
    }
}

private extension View {
    /// Liquid Glass proper, with the pre-Tahoe material as the fallback.
    @ViewBuilder
    func hudGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            glassEffect(GlassDiffusion.prefersClear ? .clear : .regular, in: shape)
        } else {
            background(shape.fill(.regularMaterial))
        }
    }
}
