import Foundation
import XCTest
@testable import FlightApp

final class ClaudeAgentTests: XCTestCase {
    func testStreamJSONInputLineUsesTextContentWithoutImages() throws {
        let line = try XCTUnwrap(ClaudeAgent.makeStreamJSONInputLine(
            message: "Explain the failing test",
            images: []
        ))

        let root = try parseObject(line)
        XCTAssertEqual(root["type"] as? String, "user")

        let message = try XCTUnwrap(root["message"] as? [String: Any])
        XCTAssertEqual(message["role"] as? String, "user")
        XCTAssertEqual(message["content"] as? String, "Explain the failing test")
    }

    func testStreamJSONInputLineIncludesBase64ImageBlocks() throws {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let line = try XCTUnwrap(ClaudeAgent.makeStreamJSONInputLine(
            message: "What changed in this screenshot?",
            images: [imageData]
        ))

        let root = try parseObject(line)
        let message = try XCTUnwrap(root["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)

        let imageBlock = content[0]
        XCTAssertEqual(imageBlock["type"] as? String, "image")
        let source = try XCTUnwrap(imageBlock["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, imageData.base64EncodedString())

        XCTAssertEqual(content[1]["type"] as? String, "text")
        XCTAssertEqual(content[1]["text"] as? String, "What changed in this screenshot?")
    }

    func testRemoteImageCommandUploadsAttachmentsBeforePromptingClaude() {
        let command = ClaudeAgent.makeRemoteCommand(
            message: "What is in this image?",
            images: [Data([1, 2, 3, 4])],
            claudeArgs: [
                "claude",
                "-p",
                "--output-format", "stream-json",
                "--verbose",
                "--dangerously-skip-permissions",
            ],
            uploadsImages: true
        )

        XCTAssertTrue(command.contains("flight-attachments-"))
        XCTAssertTrue(command.contains("python3 -c "))
        XCTAssertTrue(command.contains("claude -p \"$(cat \"$prompt_file\")\""))
        XCTAssertFalse(command.contains("'--input-format'"))
        XCTAssertFalse(command.contains("/tmp/flight-prompt.txt"))
        XCTAssertFalse(command.contains("What is in this image?"))
    }

    func testRemoteAttachmentUploadLineCarriesImageBytes() throws {
        let imageData = Data([1, 2, 3, 4])
        let line = try XCTUnwrap(ClaudeAgent.makeRemoteAttachmentUploadLine(
            message: "Inspect this",
            images: [imageData]
        ))

        let root = try parseObject(line)
        XCTAssertEqual(root["message"] as? String, "Inspect this")
        let images = try XCTUnwrap(root["images"] as? [[String: Any]])
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0]["filename"] as? String, "image-1.png")
        XCTAssertEqual(images[0]["media_type"] as? String, "image/png")
        XCTAssertEqual(images[0]["data"] as? String, imageData.base64EncodedString())
    }

    private func parseObject(_ line: String) throws -> [String: Any] {
        let data = try XCTUnwrap(line.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
