import Foundation
import Observation
import Sparkle

/// Automatic updates with Sparkle. New versions are published as GitHub
/// releases alongside an `appcast.xml` feed; Sparkle checks the feed daily,
/// verifies each download against the public key in Info.plist, and swaps
/// the app in place.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    /// False while a check is running, or when this build can't update
    /// (a development build without a feed or key).
    private(set) var canCheck = false
    private(set) var isAvailable = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    private var updater: SPUUpdater? { controller?.updater }

    /// Starts Sparkle, if this is a build that can be updated.
    func start() {
        guard controller == nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        do {
            try controller.updater.start()
        } catch {
            NSLog("Tidewall: updates are unavailable: \(error.localizedDescription)")
            return
        }
        self.controller = controller
        isAvailable = true
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            DispatchQueue.main.async { self?.canCheck = canCheck }
        }
    }

    func checkNow() {
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return updater?.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) { updater?.automaticallyChecksForUpdates = newValue }
        }
    }

    var automaticallyInstalls: Bool {
        get {
            access(keyPath: \.automaticallyInstalls)
            return updater?.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyInstalls) { updater?.automaticallyDownloadsUpdates = newValue }
        }
    }

    var lastCheck: Date? { updater?.lastUpdateCheckDate }
}
