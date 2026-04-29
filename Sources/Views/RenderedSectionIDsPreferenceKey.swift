import SwiftUI
import FlightCore

/// Each rendered chat section bubbles its UUID up through this preference
/// key. SwiftUI accumulates them via `reduce` so the parent sees the full
/// list of *realized* (LazyVStack-materialized) section IDs in document
/// order. The rendering test suite uses `onPreferenceChange` to verify the
/// realized set never escapes the paginated window.
///
/// Preferences propagate up the view tree, which forces SwiftUI to evaluate
/// the contributing children to collect their values. With one `.preference`
/// per LazyVStack section, that's a known laziness-killer at long
/// conversation lengths — so production keeps `captureEnabled` off and the
/// modifier becomes a no-op. Tests set the flag in `setUp` to opt back in.
public struct RenderedSectionIDsPreferenceKey: PreferenceKey {
    public static let defaultValue: [UUID] = []
    public static func reduce(value: inout [UUID], nextValue: () -> [UUID]) {
        value.append(contentsOf: nextValue())
    }

    public static var captureEnabled: Bool = false
}

extension View {
    /// Publishes `id` via `RenderedSectionIDsPreferenceKey` only when
    /// `captureEnabled` is set (i.e. from the rendering test suite). Skips
    /// the modifier entirely in production so SwiftUI doesn't realize
    /// off-screen LazyVStack cells just to collect preference values.
    @ViewBuilder
    public func renderedSectionID(_ id: UUID) -> some View {
        if RenderedSectionIDsPreferenceKey.captureEnabled {
            preference(key: RenderedSectionIDsPreferenceKey.self, value: [id])
        } else {
            self
        }
    }
}
