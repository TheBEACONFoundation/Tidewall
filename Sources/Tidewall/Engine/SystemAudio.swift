import AppKit
import CoreAudio
import Observation
import os

struct AudioTapError: LocalizedError {
    var step: String
    var status: OSStatus
    var errorDescription: String? { "Couldn't \(step) (error \(status))." }
}

/// Listens to the mix of everything the Mac plays, through a Core Audio
/// process tap. Samples land in a small ring buffer that the visualizer
/// analyzes; nothing is recorded or leaves memory. Needs the System Audio
/// Recording permission, which macOS asks for the first time it starts.
final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Tidewall.audio-tap", qos: .userInteractive)
    /// A plain unfair lock: safe to take briefly on the real-time audio thread.
    private let lockPointer: UnsafeMutablePointer<os_unfair_lock> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        return pointer
    }()
    private var ring = [Float](repeating: 0, count: 16_384)
    private var writeIndex = 0
    private(set) var sampleRate: Double = 48_000
    private(set) var isRunning = false

    deinit {
        stop()
        lockPointer.deallocate()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lockPointer)
        defer { os_unfair_lock_unlock(lockPointer) }
        return body()
    }

    func start() throws {
        guard !isRunning else { return }
        do {
            // A mono mixdown of every process except Tidewall itself.
            let description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tapID), "listen to system audio")

            var format = AudioStreamBasicDescription()
            try Self.read(tapID, kAudioTapPropertyFormat, into: &format)
            sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000

            let outputUID = try Self.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Tidewall Visualizer",
                kAudioAggregateDeviceUIDKey: "io.github.thebeaconfoundation.tidewall.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                                   kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "set up audio listening")
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
                self?.consume(input)
            }, "set up audio listening")
            try check(AudioDeviceStart(aggregateID, procID), "start listening")
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
        withLock {
            for i in ring.indices { ring[i] = 0 }
        }
    }

    /// Copies the newest `into.count` samples, oldest first.
    func latest(into out: inout [Float]) {
        os_unfair_lock_lock(lockPointer)
        defer { os_unfair_lock_unlock(lockPointer) }
        let n = out.count, size = ring.count
        for i in 0..<n { out[i] = ring[(writeIndex - n + i + size) % size] }
    }

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        // The tap's stream comes after any input streams of the output device.
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = buffers.last, let data = buffer.mData else { return }
        let channels = max(1, Int(buffer.mNumberChannels))
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        let samples = data.assumingMemoryBound(to: Float.self)
        os_unfair_lock_lock(lockPointer)
        defer { os_unfair_lock_unlock(lockPointer) }
        let size = ring.count
        for f in 0..<frames {
            var v: Float = 0
            for c in 0..<channels { v += samples[f * channels + c] }
            ring[writeIndex] = v / Float(channels)
            writeIndex = (writeIndex + 1) % size
        }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw AudioTapError(step: step, status: status) }
    }

    // MARK: HAL helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) throws {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        if status != noErr { throw AudioTapError(step: "read audio settings", status: status) }
    }

    static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, into: &device)
        var uid: Unmanaged<CFString>?
        try read(device, kAudioDevicePropertyDeviceUID, into: &uid)
        guard let uid else { throw AudioTapError(step: "find the output device", status: -1) }
        return uid.takeRetainedValue() as String
    }

    static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Whether any other app is currently sending audio to an output. Cheap
    /// enough to poll, and needs no permission.
    static func isOtherAudioPlaying() -> Bool {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &processes) == noErr
        else { return false }
        let me = getpid()
        for process in processes {
            var running: UInt32 = 0
            var pid: pid_t = 0
            guard (try? read(process, kAudioProcessPropertyIsRunningOutput, into: &running)) != nil, running != 0,
                  (try? read(process, kAudioProcessPropertyPID, into: &pid)) != nil, pid != me
            else { continue }
            return true
        }
        return false
    }
}

/// Shares one tap and one analysis between every visible visualizer, and only
/// listens while one is on screen and another app is actually playing sound.
@MainActor
@Observable
final class AudioReactor {
    static let shared = AudioReactor()

    /// Whether system audio is being analyzed right now.
    private(set) var isListening = false
    /// Why listening failed, for the editor to explain.
    private(set) var lastError: String?
    /// Another app has been playing for a while but everything heard is
    /// silence: most likely the permission was declined.
    private(set) var hearsOnlySilence = false

    @ObservationIgnored private var demands: [String: Int] = [:]
    @ObservationIgnored private let tap = SystemAudioTap()
    @ObservationIgnored private var analyzer = AudioAnalyzer(sampleRate: 48_000)
    @ObservationIgnored private var samples = [Float](repeating: 0, count: AudioAnalyzer.fftSize)
    @ObservationIgnored private var cached = AudioAnalyzer.Frame()
    @ObservationIgnored private var lastAnalysis: CFTimeInterval = 0
    @ObservationIgnored private var watchTimer: Timer?
    @ObservationIgnored private var quietChecks = 0
    @ObservationIgnored private var silentChecks = 0
    @ObservationIgnored private var lastLog: CFTimeInterval = 0
    @ObservationIgnored private var outputListener: AudioObjectPropertyListenerBlock?

    /// How many visible visualizers a part of the app is showing (desktop
    /// windows, the editor preview). Listening runs while the total is above 0.
    func setDemand(_ count: Int, from source: String) {
        let before = demands.values.reduce(0, +)
        demands[source] = count
        let after = demands.values.reduce(0, +)
        if (before > 0) != (after > 0) { demandChanged(active: after > 0) }
    }

    /// The analysis for this moment; several views drawing the same frame share it.
    func frame(at now: CFTimeInterval) -> AudioAnalyzer.Frame {
        if now - lastAnalysis < 0.004 { return cached }
        let dt = lastAnalysis == 0 ? 1.0 / 60 : now - lastAnalysis
        lastAnalysis = now
        if tap.isRunning {
            tap.latest(into: &samples)
        } else if samples.first != 0 || samples.last != 0 {
            for i in samples.indices { samples[i] = 0 }
        }
        cached = analyzer.analyze(samples, deltaTime: dt)
        if UserDefaults.standard.bool(forKey: "debugAudio"), now - lastLog > 1 {
            lastLog = now
            NSLog("Tidewall audio: listening=%d level=%.2f bass=%.2f mid=%.2f treble=%.2f beats=%d",
                  tap.isRunning ? 1 : 0, cached.level, cached.bass, cached.mid, cached.treble, cached.beats)
        }
        return cached
    }

    private func demandChanged(active: Bool) {
        if active {
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkPlayback() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            watchTimer = timer
            observeOutputDevice()
            checkPlayback()
        } else {
            watchTimer?.invalidate()
            watchTimer = nil
            stopTap()
        }
    }

    private func stopTap() {
        tap.stop()
        isListening = false
    }

    /// Start listening when something plays; stop ~6 s after it stops, so the
    /// audio hardware can go back to sleep.
    private func checkPlayback() {
        if SystemAudioTap.isOtherAudioPlaying() {
            quietChecks = 0
            if !tap.isRunning { startTap() }
            silentChecks = cached.isSilent ? silentChecks + 1 : 0
            let silent = silentChecks >= 4
            if hearsOnlySilence != silent { hearsOnlySilence = silent }
        } else if tap.isRunning {
            quietChecks += 1
            if quietChecks >= 4 { stopTap() }
        }
    }

    private func startTap() {
        do {
            try tap.start()
            if analyzer.sampleRate != tap.sampleRate { analyzer = AudioAnalyzer(sampleRate: tap.sampleRate) }
            lastError = nil
            isListening = true
        } catch {
            lastError = error.localizedDescription
            isListening = false
            NSLog("Tidewall: \(error.localizedDescription)")
        }
    }

    /// The tap is built around the current output; follow it to headphones etc.
    private func observeOutputDevice() {
        guard outputListener == nil else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.tap.isRunning else { return }
                self.stopTap()
                self.startTap()
            }
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
    }
}
