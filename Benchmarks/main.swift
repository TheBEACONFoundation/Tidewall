// Plays wallpapers in a real desktop-level window, exactly like the app, and
// measures what they cost: GPU utilization plus the CPU of this process, the
// window server (which composites every video frame) and the video decoder.
//
//   Scripts/benchmark.sh "name|path/to/video.mov|blur=12,saturation=1.2" ...
//
// A scenario with an empty path measures the idle baseline; the path "static"
// shows an empty desktop window.

import AppKit
import AVFoundation
import IOKit

struct Scenario {
    var name: String
    var url: URL?
    var settings = WallpaperSettings()
    /// Bake the adjustments into a playback copy first, like the app does.
    var baked = false
    /// Play but keep paused (e.g. while windows cover the desktop).
    var paused = false

    init(_ spec: String) {
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        name = parts[0]
        if parts.count > 1, !parts[1].isEmpty { url = URL(fileURLWithPath: parts[1]) }
        guard parts.count > 2 else { return }
        for pair in parts[2].split(separator: ",") {
            let kv = pair.split(separator: "=").map(String.init)
            guard kv.count == 2, let v = Double(kv[1]) else { continue }
            switch kv[0] {
            case "blur": settings.adjustments.blur = v
            case "saturation": settings.adjustments.saturation = v
            case "brightness": settings.adjustments.brightness = v
            case "vignette": settings.adjustments.vignette = v
            case "speed": settings.speed = v
            case "muted": settings.muted = v != 0
            case "zoom": settings.zoom = v
            case "baked": baked = v != 0
            case "paused": paused = v != 0
            default: print("unknown option \(kv[0])")
            }
        }
    }
}

struct Measurement {
    var gpu: Double
    var selfCPU: Double
    var windowServer: Double
    var decoder: Double
    var audio: Double
}

let measureSeconds = Int(ProcessInfo.processInfo.environment["BENCH_SECONDS"] ?? "") ?? 8
let warmupSeconds = 3.0

/// Sum of "Device Utilization %" across GPUs (no root needed).
func gpuUtilization() -> Double {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
    else { return 0 }
    defer { IOObjectRelease(iterator) }
    var total = 0.0
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        defer { IOObjectRelease(entry) }
        if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any],
           let value = stats["Device Utilization %"] as? NSNumber {
            total += value.doubleValue
        }
    }
    return total
}

/// CPU % per process over `seconds`, from the second sample of `top`.
func cpuByProcess(seconds: Int) async -> (byName: [String: Double], byPID: [Int32: Double]) {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let top = Process()
            top.executableURL = URL(fileURLWithPath: "/usr/bin/top")
            top.arguments = ["-l", "2", "-s", "\(seconds)", "-stats", "pid,command,cpu", "-o", "cpu", "-n", "80"]
            let pipe = Pipe()
            top.standardOutput = pipe
            try? top.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            top.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            let headers = lines.indices.filter { lines[$0].hasPrefix("PID") }
            var byName: [String: Double] = [:], byPID: [Int32: Double] = [:]
            if let start = headers.last {
                for line in lines[(start + 1)...] {
                    let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                    guard fields.count >= 3, let pid = Int32(fields[0]), let cpu = Double(fields[fields.count - 1]) else { continue }
                    let name = fields[1..<(fields.count - 1)].joined(separator: " ")
                    byName[name, default: 0] += cpu
                    byPID[pid] = cpu
                }
            }
            continuation.resume(returning: (byName, byPID))
        }
    }
}

@MainActor
func measure(_ scenario: Scenario) async -> Measurement {
    var window: DesktopWindow?
    var player: LoopingPlayer?

    if scenario.url?.path.hasSuffix("/static") == true, let screen = NSScreen.main {
        // A desktop window with nothing playing: the cost of the window itself.
        let w = DesktopWindow(screen: screen, displayID: "bench")
        w.orderFrontRegardless()
        window = w
    } else if let url = scenario.url, let screen = NSScreen.main {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 10
        let track = try? await asset.loadTracks(withMediaType: .video).first
        let size = (try? await track?.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        var wallpaper = Wallpaper(id: UUID(), name: scenario.name, mediaFile: url.lastPathComponent,
                                  originalFileName: url.lastPathComponent, dateAdded: .now, duration: duration,
                                  pixelWidth: size.width, pixelHeight: size.height, settings: scenario.settings)
        var playURL = url
        if scenario.baked {
            let recipe = RenditionRecipe(mediaFile: url.lastPathComponent, adjustments: wallpaper.settings.adjustments, scale: 1)
            let copy = URL(fileURLWithPath: ".build/bench/baked-\(recipe.key).mov")
            if !FileManager.default.fileExists(atPath: copy.path) {
                let start = Date.now
                try? await RenditionExporter.export(source: url, recipe: recipe, to: copy)
                FileHandle.standardError.write("baked \(scenario.name) in \(String(format: "%.1f", Date.now.timeIntervalSince(start)))s\n".data(using: .utf8)!)
            }
            playURL = copy
            wallpaper.settings.adjustments = Adjustments()
        }
        let p = LoopingPlayer(wallpaper: wallpaper, url: playURL)
        let w = DesktopWindow(screen: screen, displayID: "bench")
        w.show(wallpaper, player: p)
        p.setPlaying(!scenario.paused)
        window = w
        player = p
    }

    try? await Task.sleep(for: .seconds(warmupSeconds))

    var gpuSamples: [Double] = []
    let sampler = Task { @MainActor in
        while !Task.isCancelled {
            gpuSamples.append(gpuUtilization())
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
    let cpu = await cpuByProcess(seconds: measureSeconds)
    sampler.cancel()

    player?.invalidate()
    window?.tearDown()
    try? await Task.sleep(for: .seconds(1))

    let gpuAverage = gpuSamples.isEmpty ? 0 : gpuSamples.reduce(0, +) / Double(gpuSamples.count)
    return Measurement(gpu: gpuAverage,
                       selfCPU: cpu.byPID[ProcessInfo.processInfo.processIdentifier] ?? 0,
                       windowServer: cpu.byName["WindowServer"] ?? 0,
                       decoder: cpu.byName.filter { $0.key.hasPrefix("VTDecoderXPCSer") }.values.reduce(0, +),
                       audio: cpu.byName["coreaudiod"] ?? 0)
}

@MainActor
func run() async {
    let scenarios = CommandLine.arguments.dropFirst().map(Scenario.init)
    let rounds = Int(ProcessInfo.processInfo.environment["BENCH_ROUNDS"] ?? "") ?? 1
    var results: [String: [Measurement]] = [:]
    for round in 1...rounds {
        for scenario in scenarios {
            FileHandle.standardError.write("round \(round): \(scenario.name)\n".data(using: .utf8)!)
            results[scenario.name, default: []].append(await measure(scenario))
        }
    }

    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
    print("| Scenario | GPU % | Tidewall CPU % | WindowServer CPU % | Decoder CPU % | coreaudiod CPU % |")
    print("| --- | ---: | ---: | ---: | ---: | ---: |")
    for scenario in scenarios {
        let m = results[scenario.name]!
        print(String(format: "| %@ | %.1f | %.1f | %.1f | %.1f | %.1f |", scenario.name,
                     median(m.map(\.gpu)), median(m.map(\.selfCPU)),
                     median(m.map(\.windowServer)), median(m.map(\.decoder)), median(m.map(\.audio))))
    }
    exit(0)
}

NSApplication.shared.setActivationPolicy(.accessory)
Task { @MainActor in await run() }
NSApplication.shared.run()
