import Foundation

/// Decouples FlightApp from the Sentry SDK. The executable target sets
/// `subprocessFailureHandler` at startup (under `#if !DEBUG`); call sites
/// in this library invoke `captureSubprocessFailure` and don't import Sentry.
///
/// We deliberately do NOT forward stderr/stdout content off-box: CLI tools
/// can include credentials in error output (auth failures, signed URLs in
/// `git push` errors, etc.). The handler receives only command name +
/// exit code + a correlation ID; full context stays in the local log file
/// where the user can inspect it.
public enum SentryService {
    /// Set by FlightExecutable/FlightApp.init in release builds. Receives
    /// metadata only — never raw subprocess output.
    public static var subprocessFailureHandler: ((_ command: String, _ exitCode: Int32, _ correlationID: String) -> Void)?

    /// Records a subprocess failure: writes a correlation marker to the
    /// supplied log file (so a developer triaging a Sentry event can grep
    /// the local log for full context) and fires the registered handler.
    public static func captureSubprocessFailure(
        command: String,
        exitCode: Int32,
        logFile: URL?
    ) {
        let correlationID = UUID().uuidString

        if let logFile {
            let line = "=== SUBPROCESS FAILURE: '\(command)' exit=\(exitCode) correlation=\(correlationID) ===\n"
            if let data = line.data(using: .utf8),
               let handle = try? FileHandle(forWritingTo: logFile) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
            }
        }

        subprocessFailureHandler?(command, exitCode, correlationID)
    }
}
