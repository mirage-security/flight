# Flight

A native macOS client for Claude Code.

## Build & Run

```
swift build          # build
swift run Flight     # run the app
swift run FlightBench # run performance benchmarks
```

## Performance Targets

These targets are enforced by `swift run FlightBench`. All latency budgets
assume 120Hz ProMotion (8.3ms frame budget).

| Metric | Target | Rationale |
|---|---|---|
| `ChatSection.build` p99 @ 2000 messages | < 8.0 ms | Must fit in one 120Hz frame — `build` runs synchronously on main thread via `@Observable` |
| `ChatSection.build` avg @ 2000 messages | < 6.0 ms | Leave headroom for SwiftUI diffing after the rebuild |
| Bulk append (100 msgs into 200) + build | < 2.0 ms | Streaming batches must not stall the render loop |
| RSS delta for 2000-message conversation | < 5.0 MB | Keep memory proportional; avoid surprise growth |
| Large payload p99 (50 x 50KB tools) | < 8.0 ms | `planContent` JSON-parses every tool input in `flushTools` — big Write/Read payloads must not blow the frame budget |
| Large payload avg (50 x 50KB tools) | < 6.0 ms | Same path, average case |
| Heavy conversation p99 (2000 msgs, 50KB tools) | < 8.0 ms | Combined worst case: high message count + large payloads |
| Heavy conversation avg (2000 msgs, 50KB tools) | < 6.0 ms | Same, average case |
| `visibleSections` slice (500-section conv) | < 0.5 ms | Runs every `ChatMessageListView.body` evaluation — streaming fires this per token, so even 0.5ms × 60fps = 30ms/s overhead is too much if it regresses |
| Section ID enumeration (150 visible secs) | < 0.5 ms | Simulates `ForEach.IDGenerator.makeID` calling `section.id` per item per layout pass — the `initializeWithCopy for ChatSection` hot path from the cpu_resource.diag hang |
