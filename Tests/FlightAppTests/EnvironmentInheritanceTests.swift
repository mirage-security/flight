import XCTest
@testable import FlightApp

/// Regression coverage for the GUI-launch PATH bug: when Flight is opened
/// from Finder/Sparkle (not `swift run`), it inherits launchd's stripped
/// PATH and spawned subprocesses (`claude`, `pnpm`, brew tools) silently
/// fail to resolve. The fix is `EnvironmentService.baseEnvironment()`
/// being applied to every `Process.environment`. These tests pin that
/// invariant so removing the assignment from any spawn site fails CI.
final class EnvironmentInheritanceTests: XCTestCase {
    func testBaseEnvironmentInjectsCapturedPATH() {
        let env = EnvironmentService.baseEnvironment()
        XCTAssertEqual(env["PATH"], EnvironmentService.path,
                       "baseEnvironment must inject the captured login-shell PATH so subprocesses see the same tools the user has in Terminal.")
    }

    func testBaseEnvironmentOverridesWinOverPATH() {
        let env = EnvironmentService.baseEnvironment(overrides: ["PATH": "/custom"])
        XCTAssertEqual(env["PATH"], "/custom",
                       "Per-call overrides must apply last so callers can replace PATH if they need to.")
    }

    /// `runScriptStreaming` uses `zsh -s`, which does NOT load `.zprofile`
    /// or `.zshrc` — so whatever PATH the child sees came from us. This
    /// was the literal `pnpm install` failure path; if it regresses, this
    /// test fails immediately.
    func testRunScriptStreamingExposesCapturedPATH() async throws {
        let output = try await ShellService.runScriptStreaming(
            scriptContent: "printf %s \"$PATH\"",
            in: NSTemporaryDirectory()
        ) { _ in }

        XCTAssertEqual(output, EnvironmentService.path,
                       "runScriptStreaming must propagate EnvironmentService.path to the child shell, otherwise scripts like `pnpm install` won't find tools installed under /opt/homebrew or ~/.local/bin.")
    }
}
