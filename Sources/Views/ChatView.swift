import SwiftUI

struct ChatView: View {
    @Bindable var state: AppState
    let worktree: Worktree

    var body: some View {
        VStack(spacing: 0) {
            // Header
            chatHeader

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(worktree.messages) { message in
                            MessageView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: worktree.messages.count) { _, _ in
                    if let last = worktree.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Fix CI button
            if worktree.ciStatus?.overall == .failure {
                fixCIBar
            }

            Divider()

            // Input
            InputBarView(state: state, worktree: worktree)
        }
    }

    private var chatHeader: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(worktree.branch)
                .font(.headline)
            Spacer()
            if let prNumber = worktree.prNumber {
                Label("PR #\(prNumber)", systemImage: "arrow.triangle.pull")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if worktree.status == .creating {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Creating worktree...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if worktree.agent?.isRunning == true {
                Text("Running")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var fixCIBar: some View {
        HStack {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
            Text("CI checks failed")
                .font(.callout)
            Spacer()
            Button("Fix CI") {
                Task { await state.fixCI(for: worktree) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.red.opacity(0.1))
    }

    private var statusColor: Color {
        switch worktree.status {
        case .creating: return .yellow
        case .idle: return .gray
        case .running: return .green
        case .error: return .red
        case .done: return .blue
        }
    }
}
