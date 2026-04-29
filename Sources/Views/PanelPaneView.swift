import SwiftUI

/// Right-hand pane that renders the active worktree's panel script tree.
/// Slice 1: read-only, supports `section` and `row` nodes plus a header
/// with reload + close affordances.
struct PanelPaneView: View {
    @Bindable var state: AppState
    let worktree: Worktree
    @Environment(\.theme) private var theme

    private var runner: PanelRunner? { worktree.panelRunner }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let banner = runner?.errorBanner {
                errorBanner(banner)
                Divider()
            }
            content
        }
        .frame(minWidth: 240, idealWidth: 320, maxWidth: 480)
        .background(theme.sidebar)
    }

    private var headerTitle: String {
        if let title = runner?.title, !title.isEmpty { return title }
        if let path = runner?.scriptPath { return PanelDiscovery.panelName(for: path) }
        return "Panel"
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(headerTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer()
            Button {
                runner?.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tooltip("Reload panel")

            Button {
                state.togglePanelPane(for: worktree)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tooltip("Close panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.headerBackground)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.red)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.red.opacity(0.1))
    }

    @ViewBuilder
    private var content: some View {
        if let tree = runner?.tree {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    nodeView(tree, depth: 0)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if runner?.isRunning == true {
            placeholder("Loading…")
        } else {
            placeholder("Panel stopped")
        }
    }

    private func placeholder(_ message: String) -> some View {
        VStack {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `AnyView` because `nodeView` recurses through `.section` children —
    /// Swift can't infer an opaque return type that's defined in terms of
    /// itself.
    private func nodeView(_ node: PanelNode, depth: Int) -> AnyView {
        switch node {
        case .section(_, let title, let children):
            return AnyView(
                VStack(alignment: .leading, spacing: 2) {
                    if let title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .textCase(.uppercase)
                            .padding(.horizontal, 12)
                            .padding(.top, depth == 0 ? 4 : 8)
                            .padding(.bottom, 2)
                    }
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        nodeView(child, depth: depth + 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            )
        case .row(_, let title, let subtitle, let status):
            return AnyView(rowView(title: title, subtitle: subtitle, status: status))
        case .unknown(let typeName):
            return AnyView(
                Text("Unknown widget: \(typeName) — update Flight?")
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            )
        }
    }

    private func rowView(title: String, subtitle: String?, status: PanelStatus?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            statusDot(status)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusDot(_ status: PanelStatus?) -> some View {
        let color: Color = switch status {
        case .ok: theme.green
        case .warn: theme.yellow
        case .error: theme.red
        case .gray, .none: theme.secondaryText
        }
        return Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }
}
