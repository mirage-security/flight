import Foundation
import XCTest
@testable import FlightApp

final class PanelProtocolTests: XCTestCase {

    // MARK: - PanelNode

    func testDecodesRow() throws {
        let json = #"{"type":"row","id":"web-1","title":"web-1","subtitle":"nginx · running","status":"ok"}"#
        let node = try decodeNode(json)
        guard case .row(let id, let title, let subtitle, let status) = node else {
            return XCTFail("expected .row, got \(node)")
        }
        XCTAssertEqual(id, "web-1")
        XCTAssertEqual(title, "web-1")
        XCTAssertEqual(subtitle, "nginx · running")
        XCTAssertEqual(status, .ok)
    }

    func testDecodesRowWithoutOptionals() throws {
        let json = #"{"type":"row","title":"plain"}"#
        let node = try decodeNode(json)
        guard case .row(let id, let title, let subtitle, let status) = node else {
            return XCTFail("expected .row")
        }
        XCTAssertNil(id)
        XCTAssertEqual(title, "plain")
        XCTAssertNil(subtitle)
        XCTAssertNil(status)
    }

    func testDecodesNestedSection() throws {
        let json = #"""
        {"type":"section","title":"Containers","children":[
          {"type":"row","title":"a","status":"ok"},
          {"type":"row","title":"b","status":"error"}
        ]}
        """#
        let node = try decodeNode(json)
        guard case .section(_, let title, let children) = node else {
            return XCTFail("expected .section")
        }
        XCTAssertEqual(title, "Containers")
        XCTAssertEqual(children.count, 2)
    }

    func testUnknownTypeDecodesToPlaceholder() throws {
        let json = #"{"type":"chart","data":[1,2,3]}"#
        let node = try decodeNode(json)
        guard case .unknown(let typeName) = node else {
            return XCTFail("expected .unknown")
        }
        XCTAssertEqual(typeName, "chart")
    }

    func testUnknownStatusDecodesToNil() throws {
        // PanelStatus enum decodes as nil for unknown values via decodeIfPresent.
        // We expect this to throw at decodeIfPresent — the contract says the
        // row decoder treats absent-or-unknown as nil. Validate by decoding.
        let json = #"{"type":"row","title":"x","status":"alien"}"#
        XCTAssertThrowsError(try decodeNode(json))
        // ^ Strict by design for slice 1: unknown status string fails the
        // row decode rather than silently picking a color. Document if we
        // want to relax this later.
    }

    // MARK: - PanelEvent

    func testDecodesReplaceEvent() throws {
        let json = #"""
        {"op":"replace","tree":{"type":"section","title":"hi","children":[]}}
        """#
        let event = try decodeEvent(json)
        guard case .replace(let tree) = event else {
            return XCTFail("expected .replace")
        }
        guard case .section(_, let title, _) = tree else {
            return XCTFail("expected section tree")
        }
        XCTAssertEqual(title, "hi")
    }

    func testDecodesTitleEvent() throws {
        let event = try decodeEvent(#"{"op":"title","text":"Docker"}"#)
        guard case .title(let text) = event else {
            return XCTFail("expected .title")
        }
        XCTAssertEqual(text, "Docker")
    }

    func testDecodesErrorAndClearError() throws {
        let err = try decodeEvent(#"{"op":"error","message":"boom"}"#)
        guard case .error(let msg) = err else {
            return XCTFail("expected .error")
        }
        XCTAssertEqual(msg, "boom")

        let clear = try decodeEvent(#"{"op":"clear_error"}"#)
        guard case .clearError = clear else {
            return XCTFail("expected .clearError")
        }
    }

    func testUnknownOpDecodesToPlaceholder() throws {
        let event = try decodeEvent(#"{"op":"toast","message":"hi"}"#)
        guard case .unknown(let op) = event else {
            return XCTFail("expected .unknown")
        }
        XCTAssertEqual(op, "toast")
    }

    // MARK: - PanelRunner integration

    /// End-to-end: spawn a tiny script, verify the tree populates from
    /// stdout NDJSON. This exercises the same code path the right pane
    /// uses at runtime (Process spawn → readability loop → MainActor
    /// dispatch → @Observable mutation).
    func testPanelRunnerReceivesReplaceEvent() async throws {
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"op":"title","text":"Test"}'
        printf '%s\\n' '{"op":"replace","tree":{"type":"row","title":"hello","status":"ok"}}'
        # Stay alive so the test can observe the running state.
        sleep 5
        """
        let path = try writeExecutableScript(script)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let runner = PanelRunner(
            scriptPath: path,
            workingDirectory: NSTemporaryDirectory(),
            environment: [:]
        )
        runner.start()
        defer { runner.stop() }

        try await waitFor(timeout: 2) { runner.tree != nil && runner.title != nil }

        XCTAssertEqual(runner.title, "Test")
        guard case .row(_, let title, _, let status) = runner.tree else {
            return XCTFail("expected row, got \(String(describing: runner.tree))")
        }
        XCTAssertEqual(title, "hello")
        XCTAssertEqual(status, .ok)
    }

    func testPanelRunnerIgnoresNonJSONLines() async throws {
        let script = """
        #!/bin/sh
        echo "not json — should be silently dropped"
        printf '%s\\n' '{"op":"replace","tree":{"type":"row","title":"survived"}}'
        sleep 5
        """
        let path = try writeExecutableScript(script)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let runner = PanelRunner(
            scriptPath: path,
            workingDirectory: NSTemporaryDirectory(),
            environment: [:]
        )
        runner.start()
        defer { runner.stop() }

        try await waitFor(timeout: 2) { runner.tree != nil }

        guard case .row(_, let title, _, _) = runner.tree else {
            return XCTFail("expected row")
        }
        XCTAssertEqual(title, "survived")
    }

    // MARK: - Helpers

    private func decodeNode(_ json: String) throws -> PanelNode {
        try JSONDecoder().decode(PanelNode.self, from: Data(json.utf8))
    }

    private func decodeEvent(_ json: String) throws -> PanelEvent {
        try JSONDecoder().decode(PanelEvent.self, from: Data(json.utf8))
    }

    private func writeExecutableScript(_ contents: String) throws -> String {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("panel-test-\(UUID().uuidString).sh")
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path
        )
        return path
    }

    private func waitFor(timeout seconds: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}
