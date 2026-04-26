import Foundation
import FlightCore
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Message Generation

func randomString(length: Int) -> String {
    let chars = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,;:!?\n"
    return String((0..<length).map { _ in chars.randomElement()! })
}

func generateConversation(count: Int) -> [AgentMessage] {
    var messages: [AgentMessage] = []
    messages.reserveCapacity(count)
    var i = 0
    while i < count {
        let roll = Double.random(in: 0..<1)
        if roll < 0.60 && i + 1 < count {
            // Tool use + tool result pair (60%)
            let toolNames = ["Read", "Edit", "Bash", "Grep", "Glob", "Write", "Agent"]
            let name = toolNames.randomElement()!
            let input = "{\"path\": \"/some/file.swift\", \"description\": \"\(randomString(length: 30))\"}"
            messages.append(AgentMessage(role: .assistant, content: .toolUse(name: name, input: input)))
            messages.append(AgentMessage(role: .assistant, content: .toolResult(content: randomString(length: Int.random(in: 100...500)))))
            i += 2
        } else if roll < 0.90 {
            // Assistant text message (30%)
            let length = Int.random(in: 50...2000)
            messages.append(AgentMessage(role: .assistant, content: .text(randomString(length: length))))
            i += 1
        } else {
            // System message (10%)
            messages.append(AgentMessage(role: .system, content: .text(randomString(length: Int.random(in: 20...100)))))
            i += 1
        }
    }
    return messages
}

/// Generate a conversation where tool inputs/results are realistically large.
/// Real sessions have Write inputs with full file contents (10-100KB) and
/// Read results of similar size.  This stresses the `planContent` JSON-parse
/// path inside `flushTools`.
func generateLargePayloadConversation(toolPairs: Int, payloadKB: Int) -> [AgentMessage] {
    var messages: [AgentMessage] = []
    messages.reserveCapacity(toolPairs * 2)
    let bigContent = randomString(length: payloadKB * 1024)
    let toolNames = ["Read", "Edit", "Bash", "Write"]
    for _ in 0..<toolPairs {
        let name = toolNames.randomElement()!
        let input = "{\"file_path\": \"/some/file.swift\", \"content\": \"\(bigContent)\"}"
        messages.append(AgentMessage(role: .assistant, content: .toolUse(name: name, input: input)))
        messages.append(AgentMessage(role: .assistant, content: .toolResult(content: bigContent)))
    }
    return messages
}

/// Like generateConversation but with realistically large tool payloads.
/// Same 60/30/10 mix, but tool inputs are `payloadKB` KB and results are
/// 1-5KB — matching a real heavy agent session with big Read/Write calls.
func generateHeavyConversation(count: Int, payloadKB: Int) -> [AgentMessage] {
    var messages: [AgentMessage] = []
    messages.reserveCapacity(count)
    let bigContent = randomString(length: payloadKB * 1024)
    var i = 0
    while i < count {
        let roll = Double.random(in: 0..<1)
        if roll < 0.60 && i + 1 < count {
            let toolNames = ["Read", "Edit", "Bash", "Grep", "Glob", "Write", "Agent"]
            let name = toolNames.randomElement()!
            let input = "{\"file_path\": \"/some/file.swift\", \"content\": \"\(bigContent)\"}"
            messages.append(AgentMessage(role: .assistant, content: .toolUse(name: name, input: input)))
            messages.append(AgentMessage(role: .assistant, content: .toolResult(content: randomString(length: Int.random(in: 1024...5120)))))
            i += 2
        } else if roll < 0.90 {
            let length = Int.random(in: 50...2000)
            messages.append(AgentMessage(role: .assistant, content: .text(randomString(length: length))))
            i += 1
        } else {
            messages.append(AgentMessage(role: .system, content: .text(randomString(length: Int.random(in: 20...100)))))
            i += 1
        }
    }
    return messages
}

// MARK: - Timing Utilities

func measure(_ block: () -> Void) -> Double {
    let start = DispatchTime.now()
    block()
    let end = DispatchTime.now()
    let nanos = Double(end.uptimeNanoseconds - start.uptimeNanoseconds)
    return nanos / 1_000_000 // milliseconds
}

func currentRSSBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    if result == KERN_SUCCESS {
        return Int64(info.resident_size)
    }
    return -1
}

func formatBytes(_ bytes: Int64) -> String {
    if bytes < 0 { return "N/A" }
    let mb = Double(bytes) / (1024 * 1024)
    return String(format: "%.2f MB", mb)
}


// Prevent dead-code elimination
@inline(never)
func _blackHole<T>(_ value: T) {}

// MARK: - String repeat helper

extension String {
    static func * (lhs: String, rhs: Int) -> String {
        return String(repeating: lhs, count: rhs)
    }
}

// MARK: - Performance Targets (see CLAUDE.md)

struct PerfTarget {
    let name: String
    let limit: Double
    let unit: String
    var actual: Double = 0

    var passed: Bool { actual <= limit }
}

var targets: [PerfTarget] = [
    PerfTarget(name: "build p99 @ 2000 msgs", limit: 8.0, unit: "ms"),
    PerfTarget(name: "build avg @ 2000 msgs", limit: 6.0, unit: "ms"),
    PerfTarget(name: "bulk append+build (100→200)", limit: 2.0, unit: "ms"),
    PerfTarget(name: "RSS delta @ 2000 msgs", limit: 5.0, unit: "MB"),
    PerfTarget(name: "large payload p99 (50KB x 50)", limit: 8.0, unit: "ms"),
    PerfTarget(name: "large payload avg (50KB x 50)", limit: 6.0, unit: "ms"),
    PerfTarget(name: "heavy conv p99 (2k msgs 50KB)", limit: 8.0, unit: "ms"),
    PerfTarget(name: "heavy conv avg (2k msgs 50KB)", limit: 6.0, unit: "ms"),
    // Pagination / ForEach identity pass — guards against re-introducing the
    // crash pattern where per-render-cycle work scales with conversation size.
    // visibleSections is computed every time ChatMessageListView.body fires.
    // Section ID enumeration simulates ForEach.IDGenerator.makeID calling
    // section.id on each visible item (the initializeWithCopy hot path in the
    // cpu_resource.diag crash trace).
    PerfTarget(name: "visibleSections slice (500-sec conv)", limit: 0.5, unit: "ms"),
    PerfTarget(name: "section ID enumeration (150 secs)", limit: 0.5, unit: "ms"),
]

// MARK: - Benchmarks (with eval capture)

func benchmarkSectionBuildEval() -> (avg2k: Double, p99_2k: Double) {
    print("=" * 60)
    print("Benchmark 1: ChatSection.build latency")
    print("=" * 60)
    print("")
    print(String(format: "%-10@  %10@  %10@", "Messages" as NSString, "Avg (ms)" as NSString, "P99 (ms)" as NSString))
    print("-" * 35)

    var avg2k: Double = 0
    var p99_2k: Double = 0

    for count in [100, 500, 1000, 2000] {
        let messages = generateConversation(count: count)
        var times: [Double] = []
        times.reserveCapacity(100)

        for _ in 0..<100 {
            let t = measure {
                _ = ChatSection.build(from: messages)
            }
            times.append(t)
        }

        times.sort()
        let avg = times.reduce(0, +) / Double(times.count)
        let p99 = times[min(times.count - 1, Int(Double(times.count) * 0.99))]
        print(String(format: "%-10d  %10.3f  %10.3f", count, avg, p99))

        if count == 2000 {
            avg2k = avg
            p99_2k = p99
        }
    }
    print("")
    return (avg2k, p99_2k)
}

func benchmarkAppendSimulationEval() -> Double {
    print("=" * 60)
    print("Benchmark 2: Append simulation (200 base + 100 appended)")
    print("=" * 60)
    print("")

    let baseMessages = generateConversation(count: 200)
    let newMessages = generateConversation(count: 100)

    // (a) 100 individual appends, each followed by a build
    let timeIndividual = measure {
        var messages = baseMessages
        for msg in newMessages {
            messages.append(msg)
            _ = ChatSection.build(from: messages)
        }
    }

    // (b) One bulk append, then one build
    let timeBulk = measure {
        var messages = baseMessages
        messages.append(contentsOf: newMessages)
        _ = ChatSection.build(from: messages)
    }

    print(String(format: "%-30@  %10@", "Strategy" as NSString, "Time (ms)" as NSString))
    print("-" * 43)
    print(String(format: "%-30@  %10.3f", "Individual append + build" as NSString, timeIndividual))
    print(String(format: "%-30@  %10.3f", "Bulk append + build" as NSString, timeBulk))
    print(String(format: "%-30@  %10.1fx", "Speedup (bulk vs individual)" as NSString, timeIndividual / timeBulk))
    print("")
    return timeBulk
}

func benchmarkMemoryEval() -> Double {
    print("=" * 60)
    print("Benchmark 3: Memory (RSS) — 2000 messages")
    print("=" * 60)
    print("")

    let rssBefore = currentRSSBytes()

    let messages = generateConversation(count: 2000)
    let sections = ChatSection.build(from: messages)

    // Prevent optimizer from eliding the work
    _blackHole(messages.count)
    _blackHole(sections.count)

    let rssAfter = currentRSSBytes()

    print(String(format: "%-20@  %@", "RSS before:" as NSString, formatBytes(rssBefore) as NSString))
    print(String(format: "%-20@  %@", "RSS after:" as NSString, formatBytes(rssAfter) as NSString))
    let deltaMB: Double
    if rssBefore >= 0 && rssAfter >= 0 {
        let deltaBytes = rssAfter - rssBefore
        deltaMB = Double(deltaBytes) / (1024 * 1024)
        print(String(format: "%-20@  %@", "Delta:" as NSString, formatBytes(deltaBytes) as NSString))
    } else {
        deltaMB = 0
    }
    print(String(format: "%-20@  %d", "Messages:" as NSString, messages.count))
    print(String(format: "%-20@  %d", "Sections:" as NSString, sections.count))
    print("")
    return deltaMB
}

func benchmarkLargePayloadsEval() -> (avg50: Double, p99_50: Double) {
    print("=" * 60)
    print("Benchmark 4: Large payloads (50 tool pairs, 50KB each)")
    print("=" * 60)
    print("")
    print(String(format: "%-12@  %10@  %10@", "Payload" as NSString, "Avg (ms)" as NSString, "P99 (ms)" as NSString))
    print("-" * 37)

    var avg50: Double = 0
    var p99_50: Double = 0

    for kb in [10, 50] {
        let messages = generateLargePayloadConversation(toolPairs: 50, payloadKB: kb)
        var times: [Double] = []
        times.reserveCapacity(50)

        for _ in 0..<50 {
            let t = measure {
                _ = ChatSection.build(from: messages)
            }
            times.append(t)
        }

        times.sort()
        let avg = times.reduce(0, +) / Double(times.count)
        let p99 = times[min(times.count - 1, Int(Double(times.count) * 0.99))]
        print(String(format: "%-12@  %10.3f  %10.3f",
            "\(kb)KB x 50" as NSString, avg, p99))

        if kb == 50 {
            avg50 = avg
            p99_50 = p99
        }
    }
    print("")
    return (avg50, p99_50)
}

func benchmarkHeavyConversationEval() -> (avg: Double, p99: Double) {
    print("=" * 60)
    print("Benchmark 5: Heavy conversation (2000 msgs, 50KB tool payloads)")
    print("=" * 60)
    print("")

    let messages = generateHeavyConversation(count: 2000, payloadKB: 50)
    var times: [Double] = []
    times.reserveCapacity(50)

    for _ in 0..<50 {
        let t = measure {
            _ = ChatSection.build(from: messages)
        }
        times.append(t)
    }

    times.sort()
    let avg = times.reduce(0, +) / Double(times.count)
    let p99 = times[min(times.count - 1, Int(Double(times.count) * 0.99))]
    print(String(format: "%-10@  %10@  %10@", "Messages" as NSString, "Avg (ms)" as NSString, "P99 (ms)" as NSString))
    print("-" * 35)
    print(String(format: "%-10d  %10.3f  %10.3f", 2000, avg, p99))
    print("")
    return (avg, p99)
}

// MARK: - Benchmark 6: Pagination + ForEach identity pass

/// Benchmarks the two per-render-cycle costs introduced by the section
/// pagination fix (ChatMessageListView.visibleSections) and the ForEach
/// identity evaluation that was the initializeWithCopy hot path in the
/// cpu_resource.diag crash.
///
/// visibleSections runs every time body re-evaluates (each streaming token,
/// each new message). Section ID enumeration runs every layout pass inside
/// the ForEach. Both must stay cheap even for large conversations.
func benchmarkPaginationEval() -> (sliceAvg: Double, idEnumAvg: Double) {
    print("=" * 60)
    print("Benchmark 6: Pagination + ForEach ID enumeration")
    print("=" * 60)
    print("")

    // Simulate a large accumulated conversation (long remote session).
    let messages = generateConversation(count: 500)
    let allSections = ChatSection.build(from: messages)
    let pageSize = 150
    print(String(format: "  Total sections: %d  |  visible (capped): %d",
        allSections.count, min(allSections.count, pageSize)))
    print("")
    print(String(format: "%-40@  %10@  %10@",
        "Operation" as NSString, "Avg (ms)" as NSString, "P99 (ms)" as NSString))
    print("-" * 65)

    // 6a: visibleSections slice — Array(allSections.suffix(pageSize))
    // This mirrors the computed property that runs on every body re-evaluation.
    var sliceTimes: [Double] = []
    sliceTimes.reserveCapacity(500)
    for _ in 0..<500 {
        let t = measure {
            let visible = Array(allSections.suffix(pageSize))
            _blackHole(visible.count)
        }
        sliceTimes.append(t)
    }
    sliceTimes.sort()
    let sliceAvg = sliceTimes.reduce(0, +) / Double(sliceTimes.count)
    let sliceP99 = sliceTimes[min(sliceTimes.count - 1, Int(Double(sliceTimes.count) * 0.99))]
    print(String(format: "%-40@  %10.4f  %10.4f",
        "visibleSections slice (500→150)" as NSString, sliceAvg, sliceP99))

    // 6b: Section ID enumeration — iterating visible sections and calling .id
    // on each. This mirrors ForEach.IDGenerator.makeID's per-item cost.
    // Using direct section.id access (not the old tuple \.element.id path that
    // caused initializeWithCopy for ChatSection in the crash trace).
    let visible = Array(allSections.suffix(pageSize))
    var idTimes: [Double] = []
    idTimes.reserveCapacity(500)
    for _ in 0..<500 {
        let t = measure {
            for section in visible {
                _blackHole(section.id)
            }
        }
        idTimes.append(t)
    }
    idTimes.sort()
    let idAvg = idTimes.reduce(0, +) / Double(idTimes.count)
    let idP99 = idTimes[min(idTimes.count - 1, Int(Double(idTimes.count) * 0.99))]
    print(String(format: "%-40@  %10.4f  %10.4f",
        "section .id enumeration (150 secs)" as NSString, idAvg, idP99))

    print("")
    return (sliceAvg, idAvg)
}

// MARK: - Main

print("")
print("FlightBench — ChatSection streaming hot-path benchmarks")
print("")

let (avg2k, p99_2k) = benchmarkSectionBuildEval()
let bulkTime = benchmarkAppendSimulationEval()
let rssDeltaMB = benchmarkMemoryEval()
let (avgLarge, p99Large) = benchmarkLargePayloadsEval()
let (avgHeavy, p99Heavy) = benchmarkHeavyConversationEval()
let (sliceAvg, idEnumAvg) = benchmarkPaginationEval()

// Fill in actuals
targets[0].actual = p99_2k
targets[1].actual = avg2k
targets[2].actual = bulkTime
targets[3].actual = rssDeltaMB
targets[4].actual = p99Large
targets[5].actual = avgLarge
targets[6].actual = p99Heavy
targets[7].actual = avgHeavy
targets[8].actual = sliceAvg
targets[9].actual = idEnumAvg

// MARK: - Eval Report

print("=" * 60)
print("Performance Eval (targets from CLAUDE.md)")
print("=" * 60)
print("")
print(String(format: "%-33@  %8@  %8@  %@",
    "Target" as NSString, "Limit" as NSString,
    "Actual" as NSString, "Result" as NSString))
print("-" * 65)

var failures = 0
for t in targets {
    let result = t.passed ? "PASS" : "FAIL"
    if !t.passed { failures += 1 }
    print(String(format: "%-33@  %5.1f %@  %5.1f %@  %@",
        t.name as NSString,
        t.limit, t.unit as NSString,
        t.actual, t.unit as NSString,
        result as NSString))
}

print("")
if failures > 0 {
    print("\(failures) target(s) FAILED.")
    exit(1)
} else {
    print("All targets passed.")
}
