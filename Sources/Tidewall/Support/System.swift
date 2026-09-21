import AppKit
import IOKit.ps
import ServiceManagement

/// A connected screen, identified by a UUID that survives reboots and
/// reconnection (unlike `CGDirectDisplayID`).
struct Display: Identifiable, Hashable {
    let id: String
    let name: String
    let frame: CGRect
    let scale: CGFloat
    let isMain: Bool

    var pixelSize: CGSize { CGSize(width: frame.width * scale, height: frame.height * scale) }
    var aspectRatio: CGFloat { frame.height > 0 ? frame.width / frame.height : 16 / 10 }
    var screen: NSScreen? { NSScreen.screens.first { Display.identifier(for: $0) == id } }

    var resolutionDescription: String {
        "\(Int(pixelSize.width))×\(Int(pixelSize.height))" + (scale > 1 ? " · Retina" : "")
    }

    static var all: [Display] {
        NSScreen.screens.enumerated().map { index, screen in
            Display(id: identifier(for: screen),
                    name: screen.localizedName,
                    frame: screen.frame,
                    scale: screen.backingScaleFactor,
                    isMain: index == 0)
        }
    }

    static func identifier(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return screen.localizedName
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) {
            return string as String
        }
        return "display-\(displayID)"
    }
}

enum Preferences {
    static let pauseWhenHidden = "pauseWhenHidden"
    static let pauseInLowPowerMode = "pauseInLowPowerMode"
    static let pauseOnBattery = "pauseOnBattery"
    static let matchSystemWallpaper = "matchSystemWallpaper"
    static let showDockIcon = "showDockIcon"

    static func register() {
        UserDefaults.standard.register(defaults: [
            pauseWhenHidden: true,
            pauseInLowPowerMode: true,
            pauseOnBattery: false,
            matchSystemWallpaper: false,
            showDockIcon: true,
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    @MainActor
    static func applyDockIconPreference() {
        NSApp.setActivationPolicy(bool(showDockIcon) ? .regular : .accessory)
    }
}

extension Notification.Name {
    static let powerSourceDidChange = Notification.Name("TidewallPowerSourceDidChange")
}

enum PowerMonitor {
    private static var runLoopSource: CFRunLoopSource?

    @MainActor
    static func start() {
        guard runLoopSource == nil,
              let source = IOPSNotificationCreateRunLoopSource({ _ in
                  NotificationCenter.default.post(name: .powerSourceDidChange, object: nil)
              }, nil)?.takeRetainedValue()
        else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    static var isLowPowerModeEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

extension Double {
    /// "0:12.4" style timestamp for trim controls.
    var timecode: String {
        guard isFinite else { return "0:00.0" }
        let total = max(0, self)
        let minutes = Int(total) / 60
        let seconds = total - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, seconds)
    }

    /// "0:12" style duration for library cards.
    var shortDuration: String {
        guard isFinite else { return "0:00" }
        let total = Int(self.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
