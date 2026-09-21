import AppKit
import IOKit.ps
import ServiceManagement

/// A connected screen, identified by a UUID that survives reboots and
/// reconnection (unlike `CGDirectDisplayID`).
struct Display: Identifiable, Hashable {
    let id: String
    let name: String
    let frame: CGRect
    /// The visible frame (excluding menu bar and Dock) in Quartz global
    /// coordinates (top-left origin), as used by window lists.
    let quartzVisibleFrame: CGRect
    let scale: CGFloat
    let isMain: Bool

    var pixelSize: CGSize { CGSize(width: frame.width * scale, height: frame.height * scale) }
    var aspectRatio: CGFloat { frame.height > 0 ? frame.width / frame.height : 16 / 10 }
    var screen: NSScreen? { NSScreen.screens.first { Display.identifier(for: $0) == id } }

    var resolutionDescription: String {
        "\(Int(pixelSize.width))×\(Int(pixelSize.height))" + (scale > 1 ? " · Retina" : "")
    }

    static var all: [Display] {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.enumerated().map { index, screen in
            let visible = screen.visibleFrame
            return Display(id: identifier(for: screen),
                    name: screen.localizedName,
                    frame: screen.frame,
                    quartzVisibleFrame: CGRect(x: visible.minX, y: primaryTop - visible.maxY,
                                               width: visible.width, height: visible.height),
                    scale: screen.backingScaleFactor,
                    isMain: index == 0)
        }
    }

    static func directDisplayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    static func identifier(for screen: NSScreen) -> String {
        guard let displayID = directDisplayID(for: screen) else {
            return screen.localizedName
        }
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) {
            return string as String
        }
        return "display-\(displayID)"
    }
}

/// Measures how much of a display's desktop is hidden behind app windows.
/// Window frames are available without Screen Recording permission.
enum DesktopCoverage {
    /// Frames of on-screen, normal-level windows (all apps, including ours).
    static func windowFrames() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.5,
                  let bounds = info[kCGWindowBounds as String],
                  let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
                  rect.width >= 80, rect.height >= 80
            else { return nil }
            return rect
        }
    }

    /// Fraction of `area` covered by `windows`, sampled on a grid (cheap and
    /// exact enough for a pause decision).
    static func coveredFraction(of area: CGRect, by windows: [CGRect], columns: Int = 32, rows: Int = 20) -> Double {
        guard !area.isEmpty else { return 0 }
        let relevant = windows.filter { $0.intersects(area) }
        guard !relevant.isEmpty else { return 0 }
        var covered = 0
        for row in 0..<rows {
            let y = area.minY + (Double(row) + 0.5) * area.height / Double(rows)
            for column in 0..<columns {
                let x = area.minX + (Double(column) + 0.5) * area.width / Double(columns)
                if relevant.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { covered += 1 }
            }
        }
        return Double(covered) / Double(rows * columns)
    }
}

enum Preferences {
    static let optimizePlayback = "optimizePlayback"
    static let pauseWhenHidden = "pauseWhenHidden"
    static let pauseInLowPowerMode = "pauseInLowPowerMode"
    static let pauseOnBattery = "pauseOnBattery"
    static let matchSystemWallpaper = "matchSystemWallpaper"
    static let showDockIcon = "showDockIcon"

    static func register() {
        UserDefaults.standard.register(defaults: [
            optimizePlayback: true,
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
