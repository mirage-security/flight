import Combine
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private let updaterController: SPUStandardUpdaterController?

    var updater: SPUUpdater? {
        updaterController?.updater
    }

    private init() {
        guard Self.isConfigured else {
            updaterController = nil
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    private static var isConfigured: Bool {
        guard
            let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            !feedURL.isEmpty,
            let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            !publicKey.isEmpty
        else {
            return false
        }

        return true
    }
}

@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater?) {
        updater?
            .publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesMenuItem: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater?

    init(controller: UpdateController) {
        updater = controller.updater
        viewModel = CheckForUpdatesViewModel(updater: controller.updater)
    }

    var body: some View {
        Button("Check for Updates...") {
            updater?.checkForUpdates()
        }
        .disabled(updater == nil || !viewModel.canCheckForUpdates)
    }
}
