import SwiftUI

@main
struct TidewallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Wallpapers…") { LibraryStore.shared.presentImportPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .windowArrangement) {
                Button("Wallpaper Library") { AppDelegate.shared.showLibrary() }
                    .keyboardShortcut("0")
            }
            CommandMenu("Playback") {
                PauseCommand()
            }
        }
    }
}

private struct PauseCommand: View {
    private var engine = WallpaperEngine.shared

    var body: some View {
        Button(engine.isUserPaused ? "Resume Wallpapers" : "Pause Wallpapers") {
            engine.isUserPaused.toggle()
        }
        .keyboardShortcut("p", modifiers: [.command, .option])
    }
}

@MainActor
@Observable
final class LibraryNavigation {
    enum Section: Hashable { case wallpapers, displays }

    var section: Section? = .wallpapers
    var path: [UUID] = []
    var selection: UUID?

    func edit(_ id: UUID) {
        section = .wallpapers
        selection = id
        path = [id]
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) static var shared: AppDelegate!

    let navigation = LibraryNavigation()
    private var libraryWindow: NSWindow?
    private var launchedAsLoginItem = false

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAsLoginItem = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.register()
        Preferences.applyDockIconPreference()

        let store = LibraryStore.shared
        store.load()
        WallpaperEngine.shared.start()
        Task { await store.installSampleIfNeeded() }

        if !launchedAsLoginItem {
            showLibrary()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showLibrary()
        Task { await LibraryStore.shared.importFiles(urls) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        LibraryStore.shared.saveNow()
    }

    func showLibrary(section: LibraryNavigation.Section? = nil) {
        if let section {
            navigation.section = section
            navigation.path = []
        }
        let window = libraryWindow ?? makeLibraryWindow()
        libraryWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeLibraryWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: LibraryRootView(navigation: navigation))
        hosting.sceneBridgingOptions = [.toolbars, .title]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.title = "Tidewall"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 560)
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        window.setFrameAutosaveName("LibraryWindow")
        return window
    }
}
