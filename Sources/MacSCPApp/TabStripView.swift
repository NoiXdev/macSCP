import SwiftUI
import macSCPCore

/// The window tab strip (M8a) — between toolbar and pane heads. Pure
/// rendering: all rules live in `TabsViewModel`/`SessionTab`.
struct TabStripView: View {
    let tabs: [SessionTab]
    let activeTabID: UUID
    let onActivate: (UUID) -> Void
    let onClose: (SessionTab) -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        TabItemView(
                            tab: tab,
                            isActive: tab.id == activeTabID,
                            onActivate: { onActivate(tab.id) },
                            onClose: { onClose(tab) })
                    }
                }
            }
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.inkTertiary)
            .help(L10n.string("tabs.newTabHelp", "New tab (⌘N)"))
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        // The mockup's "paper" (window ground) token had no consumer left
        // after M6a and was dropped from `DesignTokens`; there is no custom
        // replacement, so the strip uses the same surface the rest of the
        // window falls back to when nothing overrides it: the system
        // window background.
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.hairline).frame(height: 1)
        }
    }
}

private struct TabItemView: View {
    let tab: SessionTab
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private enum Indicator { case none, upload, download, attention }

    /// Attention (static red) wins over activity; activity color follows
    /// the LAST STARTED item's direction (spec 2).
    private var indicator: Indicator {
        if tab.conflictBridge.currentPrompt != nil
            || tab.transferQueue.failedCount > tab.seenFailureCount {
            return .attention
        }
        guard tab.transferQueue.isActive else { return .none }
        return tab.transferQueue.lastStartedDirection == .upload ? .upload : .download
    }

    var body: some View {
        HStack(spacing: 7) {
            switch indicator {
            case .none: EmptyView()
            case .upload: dot(DesignTokens.localAmber, pulse: true)
            case .download: dot(DesignTokens.remoteBlue, pulse: true)
            case .attention: dot(.red, pulse: false)
            }
            Text(tab.displayTitle)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .italic(!tab.isConnected)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(
                    isActive ? DesignTokens.ink
                    : tab.isConnected ? DesignTokens.inkSecondary : DesignTokens.inkTertiary)
            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 15, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.inkTertiary)
            } else {
                Color.clear.frame(width: 15, height: 15)
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 120, maxWidth: 200, maxHeight: .infinity)
        .background(isActive ? DesignTokens.card : .clear)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle().fill(DesignTokens.remoteBlue).frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            if !isActive { Rectangle().fill(DesignTokens.hairline).frame(width: 1) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityState)
    }

    private var accessibilityState: String {
        switch indicator {
        case .none: return ""
        case .upload: return L10n.string("tabs.a11y.uploading", "uploading")
        case .download: return L10n.string("tabs.a11y.downloading", "downloading")
        case .attention: return L10n.string("tabs.a11y.attention", "needs attention")
        }
    }

    @ViewBuilder
    private func dot(_ color: Color, pulse: Bool) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulse && pulsing && !reduceMotion ? 0.35 : 1.0)
            .animation(
                pulse && !reduceMotion
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : nil,
                value: pulsing)
            .onAppear { pulsing = pulse }
    }
}
