import Combine
import Foundation
import Sparkle

@MainActor final class Updater: ObservableObject {
    let controller: SPUStandardUpdaterController?
    @Published private(set) var canCheckForUpdates = false

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}
