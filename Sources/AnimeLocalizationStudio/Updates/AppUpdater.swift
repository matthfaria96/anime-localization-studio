import AppKit
import Combine
import Sparkle
import SwiftUI

/// In-app updates through Sparkle, the same as every witchmymac app. The feed (SUFeedURL), the
/// EdDSA public key (SUPublicEDKey) and the daily check live in Resources/Info.plist; versions are
/// signed with the witchmymac EdDSA key and the app with the witchmymac certificate.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    /// False while a check or an install is already running.
    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    private override init() {
        super.init()
    }

    /// Starts Sparkle's scheduler (daily check), once, when the app opens. Test copies (run from
    /// dist/ or with a throwaway home) do not check unless ALS_UPDATES=1.
    func start() {
        guard controller == nil else { return }
        let env = ProcessInfo.processInfo.environment
        let installed = Bundle.main.bundleURL.path.hasPrefix("/Applications/") && env["CFFIXED_USER_HOME"] == nil
        guard installed || env["ALS_UPDATES"] == "1" else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            DispatchQueue.main.async { self?.canCheckForUpdates = canCheck }
        }
        controller.startUpdater()
    }

    /// “Verificar atualizações…”: always shows a result, even “you are up to date”.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// The menu item and the button in Sobre; disabled while a check is already running.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Button("Verificar atualizações…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
