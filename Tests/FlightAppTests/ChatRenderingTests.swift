import XCTest
import SwiftUI
import AppKit
import FlightCore
@testable import FlightApp

/// NSHostingView-driven tests for `ChatMessageListView`.
///
/// SwiftUI's `.accessibilityIdentifier` doesn't propagate to NSView's
/// queryable `accessibilityIdentifier` from a unit-test process, so each
/// rendered section publishes its UUID via
/// `RenderedSectionIDsPreferenceKey`. The host wraps the chat view in an
/// `onPreferenceChange` observer that captures whatever IDs the SwiftUI
/// runtime actually realized.
///
/// What these tests catch:
/// - The view crashes when hosted with a conversation of any size.
/// - Realized section IDs always trace back to a real ChatSection in
///   the conversation — i.e. ForEach isn't generating garbage IDs and
///   the preference plumbing is intact.
///
/// What they intentionally don't try to verify:
/// - The exact realized count, or which slice of indices is realized at
///   any given scroll position. LazyVStack realizes a viewport-sized
///   buffer plus some surrounding pre-realization, and scrolling to the
///   top of the loaded window triggers the loadMore sentinel, expanding
///   the window. Both are correct behaviors; both make
///   "rendered IDs are exactly within the initial paginated window"
///   too brittle to assert reliably from a unit test. The pagination
///   *math* is exhaustively covered by `ChatPaginationTests` in
///   FlightCoreTests.
@MainActor
final class ChatRenderingTests: XCTestCase {

    // MARK: - Fixtures

    private func makeConversation(messageCount: Int) -> Conversation {
        let messages = (0..<messageCount).map { i in
            AgentMessage(
                role: i.isMultiple(of: 2) ? .assistant : .user,
                content: .text("msg-\(i)")
            )
        }
        let conv = Conversation(name: "Test")
        conv.setMessages(messages)
        return conv
    }

    private func makeWorktree(conversation: Conversation) -> Worktree {
        let wt = Worktree(
            branch: "test-\(UUID().uuidString.prefix(6))",
            path: NSTemporaryDirectory()
        )
        wt.conversations = [conversation]
        wt.activeConversationID = conversation.id
        return wt
    }

    private final class IDCollector {
        var ids: [UUID] = []
    }

    private struct HostingWrapper: View {
        @Bindable var state: AppState
        let worktree: Worktree
        let onChange: ([UUID]) -> Void

        var body: some View {
            ChatMessageListView(state: state, worktree: worktree)
                .onPreferenceChange(RenderedSectionIDsPreferenceKey.self) { ids in
                    onChange(ids)
                }
        }
    }

    private var window: NSWindow?

    private func host(_ conversation: Conversation) -> IDCollector {
        let wt = makeWorktree(conversation: conversation)
        let state = AppState()
        let collector = IDCollector()

        let wrapper = HostingWrapper(state: state, worktree: wt) { ids in
            collector.ids = ids
        }
        let hostView = NSHostingView(rootView: wrapper)
        hostView.frame = NSRect(x: 0, y: 0, width: 800, height: 1200)

        // Attach to an offscreen window — required for .onAppear and
        // ScrollView materialization to fire. Without a window the host
        // never produces realized children and the collector stays empty.
        let win = NSWindow(
            contentRect: hostView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentView = hostView
        win.orderOut(nil)
        self.window = win

        hostView.layoutSubtreeIfNeeded()
        // Pump the runloop so .onAppear, scrollToBottom, and the
        // PreferenceKey callback all settle.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        hostView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        return collector
    }

    override func setUp() {
        super.setUp()
        // Production keeps the per-section preference modifier off (it
        // breaks LazyVStack laziness on long conversations). The test relies
        // on the bubbled IDs to verify what was realized, so opt back in
        // for the lifetime of the test.
        RenderedSectionIDsPreferenceKey.captureEnabled = true
    }

    override func tearDown() {
        RenderedSectionIDsPreferenceKey.captureEnabled = false
        window?.contentView = nil
        window = nil
        super.tearDown()
    }

    // MARK: - Smoke

    func testHostsEmptyConversationWithoutCrashing() {
        _ = host(makeConversation(messageCount: 0))
    }

    func testHostsShortConversationWithoutCrashing() {
        _ = host(makeConversation(messageCount: 50))
    }

    func testHostsLongConversationWithoutCrashing() {
        _ = host(makeConversation(messageCount: 1000))
    }

    // MARK: - Invariant: realized IDs trace back to the conversation

    func testRealizedSectionIDsAreValidSectionsOfTheConversation() {
        let conv = makeConversation(messageCount: 200)
        let collector = host(conv)

        let validIDs = Set(conv.sections.map(\.id))

        XCTAssertFalse(
            collector.ids.isEmpty,
            "expected at least one section to render in a 200-msg conversation"
        )
        XCTAssertTrue(
            Set(collector.ids).isSubset(of: validIDs),
            "every realized section ID must trace back to a real section " +
            "(catches ForEach generating stale/garbage IDs or PreferenceKey wiring breaking)"
        )
    }
}
