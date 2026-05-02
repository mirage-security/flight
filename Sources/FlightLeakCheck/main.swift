import Foundation

/// Replays the `Process` + `Pipe` shape that `ShellService.runScriptStreaming`
/// uses, then asserts the parent's FD table doesn't grow. Catches the
/// regression where the Pipe's read-side `FileHandle` isn't closed after
/// the read loop reaches EOF — without that close, Foundation keeps the
/// FD alive through the dead Process and every spawn leaks one FD.
///
/// Why an out-of-process binary instead of an XCTest case: XCTest's harness
/// (Task.detached reaping, dispatch source teardown, killed-xctest zombie
/// reparenting) adds enough timing noise that an FD-counting test inside
/// `swift test` is flaky. A plain `swift run` binary spawns subprocesses
/// the same way Flight does in production and lets us count FDs without
/// the harness in the way. `./test.sh` runs this after `swift test`.

func openFDCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
}

/// Mirrors `ShellService.runScriptStreaming`: `zsh -s` reading the script
/// from stdin, with stderr redirected to stdout. The crucial bit being
/// tested is that the parent closes `stdoutPipe.fileHandleForReading` once
/// the read loop sees EOF.
func runScript(_ script: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
    proc.arguments = ["-s"]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    proc.standardInput = stdinPipe
    proc.standardOutput = stdoutPipe
    proc.standardError = stdoutPipe

    do {
        try proc.run()
    } catch {
        FileHandle.standardError.write(Data("spawn failed: \(error)\n".utf8))
        exit(2)
    }

    let wrapped = "exec 2>&1\n" + script
    if let data = wrapped.data(using: .utf8) {
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }
    try? stdinPipe.fileHandleForWriting.close()

    let readFH = stdoutPipe.fileHandleForReading
    _ = readFH.readDataToEndOfFile()
    proc.waitUntilExit()
    try? readFH.close()
}

let iterations = 50
let maxLeak = 5  // headroom for runtime noise

// Warm-up so first-spawn one-time costs (dyld caches, NSFileHandle
// dispatch source setup) don't show up in the baseline.
runScript("echo warm")

let baseline = openFDCount()
for _ in 0..<iterations {
    runScript("echo hi")
}
let after = openFDCount()
let delta = after - baseline

print("baseline=\(baseline) after=\(after) delta=\(delta) iterations=\(iterations) maxLeak=\(maxLeak)")

if delta > maxLeak {
    FileHandle.standardError.write(Data("FAIL: leaked \(delta) FDs across \(iterations) spawns (max \(maxLeak))\n".utf8))
    exit(1)
}
