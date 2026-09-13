import SwiftUI

// MARK: - Theme

/// The design tokens the home screen and the settings screen share.
///
/// Kept in one place so the two screens cannot drift: the surface colour, the
/// corner radii and the status palette are the whole visual language, and they
/// are small enough that a "component library" would be ceremony.
enum AppTheme {
    static let accent = Color(red: 0.16, green: 0.68, blue: 0.76)
    static let good = Color(red: 0.28, green: 0.76, blue: 0.49)
    static let warn = Color(red: 0.95, green: 0.67, blue: 0.25)
    static let bad = Color(red: 0.91, green: 0.36, blue: 0.35)

    enum Radius {
        static let card: CGFloat = 18
        static let control: CGFloat = 12
    }

    enum Pad {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }
}

/// A raised surface. Every block on the home screen is one of these.
struct Card<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = AppTheme.Pad.l, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

/// A compact state pill: icon, label, and a tint that carries the meaning.
struct StatusChip: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().stroke(tint.opacity(0.28), lineWidth: 1))
    }
}

// MARK: - Button styles

struct PrimaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [AppTheme.accent, AppTheme.accent.opacity(0.78)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

struct SecondaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.15))
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

// MARK: - Home

/// The app's front door: what this device can do, and the two things worth
/// starting from here.
///
/// It replaces the row of entitlement badges and the horizontally scrolling
/// button strip that used to hold every entry point at once. The controls that
/// are configuration rather than action moved to `SettingsView`; what is left
/// here is state you need to see before pressing anything.
struct HomeView: View {
    @ObservedObject private var status = RunStatus.shared
    @ObservedObject private var jit = JITState.shared

    let entitlements: EntitlementStatus?
    let onEnableJIT: () -> Void
    let onLaunchDesktop: () -> Void
    let onLaunchSteam: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Pad.m) {
            header
            Card(padding: AppTheme.Pad.m) {
                VStack(alignment: .leading, spacing: AppTheme.Pad.m) {
                    statusRow
                    actions
                }
            }
            if case .failed(let message) = status.phase {
                failureBanner(message)
            }
        }
        .padding(.horizontal, AppTheme.Pad.l)
        .padding(.top, AppTheme.Pad.s)
        .padding(.bottom, AppTheme.Pad.m)
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .fill(LinearGradient(colors: [AppTheme.accent, AppTheme.accent.opacity(0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 44, height: 44)
                .overlay(
                    Text("M")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Madeira")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                Text(DeviceCapabilities.machine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.accent.opacity(0.14)))
            }
            .accessibilityLabel("Settings")
        }
    }

    private var statusRow: some View {
        // Wraps rather than truncates: an iPad in a narrow split view has less
        // width than the four chips want, and a clipped status chip is worse
        // than a second line.
        FlowRow(spacing: 6) {
            // Two facts, one chip. `capable` is CS_DEBUGGED and is what "JIT
            // works" means; it stays set after the app deliberately detaches.
            // The old chip showed P_TRACED instead, so it flipped to "JIT off"
            // a second or two into every run while JIT was still working. The
            // detached suffix is the other, less alarming fact: a new pool needs
            // the debugger back, which the next launch does for itself.
            StatusChip(icon: jit.capable ? "bolt.fill" : "bolt.slash.fill",
                       text: jit.chipText,
                       tint: jit.capable ? AppTheme.good : AppTheme.warn)
            if let ents = entitlements {
                StatusChip(icon: "memorychip",
                           text: ents.increasedMemory ? "Memory+" : "No memory+",
                           tint: ents.increasedMemory ? AppTheme.good : AppTheme.warn)
                StatusChip(icon: "square.stack.3d.up",
                           text: ents.extendedVA ? "64-bit VA" : "No 64-bit VA",
                           tint: ents.extendedVA ? AppTheme.good : AppTheme.warn)
            }
            if status.poolMB > 0 {
                StatusChip(icon: "cpu",
                           text: "Pool \(status.poolMB) MB",
                           tint: AppTheme.accent)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: onEnableJIT) {
                Label("Enable JIT", systemImage: "bolt.fill")
            }
            .buttonStyle(PrimaryActionStyle())

            HStack(spacing: 10) {
                Button(action: onLaunchDesktop) {
                    Label("Windows Desktop", systemImage: "display")
                }
                .buttonStyle(SecondaryActionStyle())
                .disabled(status.phase.isBusy)

                Button(action: onLaunchSteam) {
                    Label("Steam", systemImage: "gamecontroller")
                }
                .buttonStyle(SecondaryActionStyle())
                .disabled(status.phase.isBusy)
            }

            if status.phase.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(status.phase == .preparing ? "Preparing…" : "Running")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func failureBanner(_ message: String) -> some View {
        Card(padding: AppTheme.Pad.m) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.bad)
                VStack(alignment: .leading, spacing: 3) {
                    Text("The last run could not start")
                        .font(.system(size: 14, weight: .semibold))
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Press a launch button to try again.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A wrapping row. SwiftUI has no `flex-wrap`, and the status chips are the one
/// place in this UI where a fixed count does not fit every width.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y),
                      anchor: .topLeading,
                      proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
