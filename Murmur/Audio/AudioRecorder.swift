import AVFoundation
import CoreAudio
import OSLog

actor AudioRecorder {
    enum RecorderError: Error, LocalizedError {
        case engineFailed(String)
        case conversionFailed
        case deviceSelectionFailed(OSStatus)
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .engineFailed(let detail): return "Audio engine failed: \(detail)"
            case .conversionFailed: return "Audio conversion setup failed."
            case .deviceSelectionFailed(let status):
                return "Could not select the requested microphone (Core Audio error \(status))."
            case .noInputDevice: return "No microphone connected."
            }
        }
    }

    /// Identifies one start()…stop() recording, so a late stop can't end a newer one.
    struct Session: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    /// Pass to stop(tailMilliseconds:) on a hold-to-talk release: capture keeps
    /// running this long so the last phoneme (and the partly filled tap buffer)
    /// isn't clipped.
    static let releaseTailMilliseconds = 150

    // ponytail: fixed debounce window and restart cap; tune if a device needs more.
    private static let restartDebounceNanoseconds: UInt64 = 150_000_000
    private static let maxRestartsPerRecording = 5

    private let log = Logger(subsystem: "com.murmur.app", category: "audio-recorder")

    private let engine = AVAudioEngine()
    private var liveLevel: Float = 0
    private let inputNoiseFloor: Float = 0.015
    private let inputCeiling: Float = 0.18
    private var sampleRate: Double = 16_000
    /// When set, records from this device (if connected) instead of the system default.
    private var preferredDeviceUID: String?
    /// Record from the built-in mic instead of a Bluetooth system default, so AirPods
    /// don't drop into low-quality HFP. A pinned mic always wins. No-op on Macs without
    /// a built-in mic, or while the lid is closed.
    private var avoidBluetoothInput = false
    private var nextSessionID: UInt64 = 0
    /// The newest recording nobody has stopped yet. It outlives a dead engine
    /// (limit hit, mic unplugged) so stop() can still return what was captured.
    private var current: Capture?
    /// The recording the installed tap feeds; nil once the engine is torn down.
    private var engineCapture: Capture?
    /// The device the engine was opened on (nil: the engine's own default).
    private var activeDeviceID: AudioDeviceID?
    private var lastDidOverflow = false
    private var tapInstalled = false
    /// Kept so deinit can remove it; the HAL holds the block until then.
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private let defaultDeviceListenerQueue = DispatchQueue.global(qos: .userInitiated)
    private var configurationObserver: NSObjectProtocol?
    private var restartTask: Task<Void, Never>?
    var onLimitReached: (@Sendable () -> Void)?
    /// Recording died mid-session (e.g. device unplug and restart failed) —
    /// without this the HUD keeps showing "recording" over a dead mic. The audio
    /// captured so far is kept: stop(session:) still returns it.
    var onRecordingFailed: (@Sendable (String) -> Void)?

    /// One recording's samples and chunk pipeline. Tap callbacks run on the audio
    /// render thread; yielding into the stream keeps chunks strictly ordered, and
    /// one consumer task appends them here.
    // Only touched on the recorder actor; @unchecked so the consumer task can hand it back.
    private final class Capture: @unchecked Sendable {
        let session: Session
        let meterOnly: Bool
        var buffer: AudioBuffer
        var continuation: AsyncStream<([Float], Float)>.Continuation?
        var consumeTask: Task<Void, Never>?
        var limitTriggered = false
        var restarts = 0

        init(session: Session, maxSamples: Int, meterOnly: Bool) {
            self.session = session
            self.meterOnly = meterOnly
            self.buffer = AudioBuffer(maxSamples: maxSamples)
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        if let defaultDeviceListener {
            var address = Self.defaultInputDeviceAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, defaultDeviceListenerQueue, defaultDeviceListener
            )
        }
    }

    func setOnLimitReached(_ callback: (@Sendable () -> Void)?) {
        onLimitReached = callback
    }

    func setOnRecordingFailed(_ callback: (@Sendable (String) -> Void)?) {
        onRecordingFailed = callback
    }

    /// Starts a new recording and returns its session for stop(session:). A previous
    /// recording nobody stopped is abandoned. `meterOnly` (mic test) keeps just the
    /// live level: no samples, no length limit.
    @discardableResult
    func start(
        maxSeconds: Int,
        preferredDeviceUID: String? = nil,
        avoidBluetoothInput: Bool = false,
        meterOnly: Bool = false
    ) throws -> Session {
        restartTask?.cancel()
        restartTask = nil
        current?.continuation?.finish()
        current = nil
        self.preferredDeviceUID = preferredDeviceUID
        self.avoidBluetoothInput = avoidBluetoothInput
        liveLevel = 0

        nextSessionID &+= 1
        let capture = Capture(
            session: Session(id: nextSessionID),
            maxSamples: meterOnly ? 0 : Int(sampleRate) * maxSeconds,
            meterOnly: meterOnly
        )
        let (stream, continuation) = AsyncStream.makeStream(of: ([Float], Float).self)
        capture.continuation = continuation
        capture.consumeTask = Task { [weak self] in
            for await (chunk, level) in stream {
                await self?.consume(chunk: chunk, level: level, capture: capture)
            }
        }

        installDefaultDeviceListenerIfNeeded()
        installConfigurationObserverIfNeeded()

        do {
            try startEngineOnBestDevice(feeding: capture)
        } catch {
            continuation.finish()
            capture.continuation = nil
            throw error
        }
        current = capture
        return capture.session
    }

    /// Stops `session` (or whatever is current, when nil) and returns its samples.
    /// A stale session — already stopped, or replaced by a newer start() — gets []
    /// and the newer recording keeps running. `tailMilliseconds` keeps capturing
    /// that long first (see releaseTailMilliseconds).
    func stop(session: Session? = nil, tailMilliseconds: Int = 0) async -> [Float] {
        guard let capture = current, session == nil || session == capture.session else { return [] }
        // Claim it before the first await, so a concurrent stop can't stop it twice.
        current = nil
        restartTask?.cancel()
        restartTask = nil
        if tailMilliseconds > 0, engineCapture === capture, engine.isRunning, !capture.meterOnly {
            try? await Task.sleep(nanoseconds: UInt64(tailMilliseconds) * 1_000_000)
        }
        // A start() during the tail took the engine over for its own recording.
        if engineCapture === capture {
            stopEngine()
        }
        if current == nil { liveLevel = 0 }
        // Drain in-flight chunks before snapshotting, or the tail of the last word
        // (anything yielded but not yet consumed) is silently dropped.
        capture.continuation?.finish()
        capture.continuation = nil
        await capture.consumeTask?.value
        capture.consumeTask = nil
        lastDidOverflow = capture.buffer.didOverflow
        // `capture` dies with this call, so the recorder doesn't hold the samples.
        return capture.buffer.samples
    }

    func currentLevel() -> Float { liveLevel }
    /// Whether the most recently stopped recording hit its length cap.
    func didOverflow() -> Bool { lastDidOverflow }
    func currentSampleCount() -> Int { current?.buffer.samples.count ?? 0 }
    func currentSamples() -> [Float] { current?.buffer.samples ?? [] }
    /// The current recording's samples from `index` on, so pollers copy only the new tail.
    func samples(from index: Int) -> [Float] { current?.buffer.samples(from: index) ?? [] }
    /// False once the engine stopped feeding the current recording (limit hit, mic lost).
    func isCapturing() -> Bool { current != nil && engineCapture === current }

    /// Opens the best input and starts the tap feeding `capture`, trying each device
    /// once: the pinned mic, then the system default, then the built-in mic. With
    /// avoidBluetoothInput, the built-in mic is tried ahead of a Bluetooth default.
    private func startEngineOnBestDevice(feeding capture: Capture) throws {
        var tried: [AudioDeviceID] = []
        var lastError: Error?
        func attempt(_ deviceID: AudioDeviceID?) -> Bool {
            guard let deviceID, !tried.contains(deviceID) else { return false }
            tried.append(deviceID)
            do {
                try startEngine(on: deviceID, feeding: capture)
                return true
            } catch {
                log.error("Mic start on device \(deviceID) failed: \(String(describing: error), privacy: .public)")
                lastError = error
                return false
            }
        }

        func attemptAvoidingBluetooth(_ deviceID: AudioDeviceID?) -> Bool {
            if avoidBluetoothInput, let deviceID, AudioInputDeviceManager.isBluetooth(deviceID),
               attempt(AudioInputDeviceManager.builtInInputDeviceID()) {
                return true
            }
            return attempt(deviceID)
        }

        // An explicitly pinned mic wins, Bluetooth or not: the user chose that trade-off.
        if attempt(preferredDeviceUID.flatMap(AudioInputDeviceManager.deviceID(forUID:))) { return }
        if attemptAvoidingBluetooth(AudioInputDeviceManager.systemDefaultInputDeviceID()) { return }
        if attempt(AudioInputDeviceManager.builtInInputDeviceID()) { return }
        if tried.isEmpty {
            // No device resolved at all: let the engine use its own default.
            // configureTap throws noInputDevice if there really is no mic.
            do {
                try startEngine(on: nil, feeding: capture)
                return
            } catch {
                lastError = error
            }
        }
        resetEngineHard()
        throw lastError ?? RecorderError.noInputDevice
    }

    private func startEngine(on deviceID: AudioDeviceID?, feeding capture: Capture) throws {
        stopEngine()
        engine.reset()
        if let deviceID {
            try applyInputDevice(deviceID)
        }

        do {
            try configureTap(continuation: capture.continuation)
        } catch {
            log.error("configureTap failed: \(String(describing: error), privacy: .public)")
            throw error
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            log.error("engine.start failed: \(String(describing: error), privacy: .public)")
            let hwFormat = engine.inputNode.outputFormat(forBus: 0)
            log.error("inputNode format at failure: sr=\(hwFormat.sampleRate) ch=\(hwFormat.channelCount)")
            throw RecorderError.engineFailed(error.localizedDescription)
        }
        engineCapture = capture
        activeDeviceID = deviceID
        log.info("Recording from input device \(deviceID.map { String($0) } ?? "engine default", privacy: .public)")
    }

    private func stopEngine() {
        removeTapIfInstalled()
        engine.stop()
        engineCapture = nil
        activeDeviceID = nil
    }

    private func resetEngineHard() {
        stopEngine()
        engine.reset()
    }

    private func configureTap(continuation: AsyncStream<([Float], Float)>.Continuation?) throws {
        let input = engine.inputNode
        // installTap raises an uncatchable Objective-C exception on a 0 Hz / 0 ch
        // format, which is what the input node reports when no mic is connected.
        let hardwareFormat = input.inputFormat(forBus: 0)
        let tapFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              tapFormat.sampleRate > 0, tapFormat.channelCount > 0
        else { throw RecorderError.noInputDevice }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw RecorderError.conversionFailed }

        let converterBox = ConverterBox()
        let noiseFloor = inputNoiseFloor
        let ceiling = inputCeiling

        removeTapIfInstalled()
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { pcm, _ in
            guard pcm.format.sampleRate > 0, pcm.format.channelCount > 0 else { return }
            let source = Self.monoBuffer(from: pcm, channelEnergy: &converterBox.channelEnergy) ?? pcm
            let inputFormat = source.format

            let converter: AVAudioConverter
            if let cached = converterBox.converter(matching: inputFormat) {
                converter = cached
            } else {
                guard let made = AVAudioConverter(from: inputFormat, to: targetFormat) else { return }
                // Only non-Float32 multichannel input reaches here unmixed; mix it rather
                // than keep channel 0.
                made.downmix = true
                converterBox.store(converter: made, format: inputFormat)
                converter = made
            }

            let frameCapacity = AVAudioFrameCount(
                max(1.0, targetFormat.sampleRate * Double(source.frameLength) / inputFormat.sampleRate)
            )
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
            var error: NSError?
            // The input block may be invoked more than once per convert() when the
            // rate converter needs priming; feeding the same buffer twice duplicates
            // audio, so hand it over exactly once.
            var provided = false
            converter.convert(to: outBuf, error: &error) { _, status in
                if provided {
                    status.pointee = .noDataNow
                    return nil
                }
                provided = true
                status.pointee = .haveData
                return source
            }
            if error != nil { return }
            let count = Int(outBuf.frameLength)
            guard let channel = outBuf.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
            let level = Self.meterLevel(chunk, noiseFloor: noiseFloor, ceiling: ceiling)
            continuation?.yield((chunk, level))
        }
        tapInstalled = true
    }

    /// Mixes the channels that carry signal into one. AVAudioConverter's default channel
    /// map keeps only channel 0, so a mic on input 2 of an audio interface would record
    /// silence; a plain average would cut a lone mic on an N-input interface by
    /// 20·log10(N) dB, under the fixed silence gates downstream. Channels within 20 dB of
    /// the loudest are averaged, so a lone mic or an identical stereo pair stays at full
    /// level and idle inputs add no noise. `channelEnergy` is the smoothed per-channel
    /// mean square, carried from one buffer to the next so the selection doesn't flip.
    /// Nil when the buffer is already mono or isn't Float32.
    // ponytail: a mic more than 20 dB under a hot line input on the same device is dropped.
    static func monoBuffer(from pcm: AVAudioPCMBuffer, channelEnergy: inout [Float]) -> AVAudioPCMBuffer? {
        let channels = Int(pcm.format.channelCount)
        let frames = Int(pcm.frameLength)
        guard channels > 1,
              let source = pcm.floatChannelData,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: pcm.format.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: pcm.frameLength),
              let out = mono.floatChannelData?[0]
        else { return nil }

        // Interleaved samples all live behind the first pointer, `channels` apart.
        let interleaved = pcm.format.isInterleaved
        func sample(_ frame: Int, _ channel: Int) -> Float {
            interleaved ? source[0][frame * channels + channel] : source[channel][frame]
        }

        if channelEnergy.count != channels { channelEnergy = Array(repeating: 0, count: channels) }
        for channel in 0..<channels {
            var sumSquares: Float = 0
            for frame in 0..<frames {
                let value = sample(frame, channel)
                sumSquares += value * value
            }
            let meanSquare = sumSquares / Float(max(frames, 1))
            guard meanSquare.isFinite else { continue }
            // Quick to pick up a channel that starts carrying sound, slow to drop one
            // that pauses between words.
            let rate: Float = meanSquare > channelEnergy[channel] ? 0.5 : 0.05
            channelEnergy[channel] += (meanSquare - channelEnergy[channel]) * rate
        }
        let loudest = channelEnergy.max() ?? 0
        // Everything near digital silence: nothing to pick, so plain-average them all.
        let active = loudest < 1e-10
            ? Array(0..<channels)
            : (0..<channels).filter { channelEnergy[$0] * 100 >= loudest }
        let scale = 1 / Float(active.count)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in active { sum += sample(frame, channel) }
            out[frame] = sum * scale
        }
        mono.frameLength = pcm.frameLength
        return mono
    }

    private func removeTapIfInstalled() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func applyInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            log.error("Failed to select input device \(deviceID): Core Audio status \(status)")
            throw RecorderError.deviceSelectionFailed(status)
        }
    }

    private static let defaultInputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func installDefaultDeviceListenerIfNeeded() {
        guard defaultDeviceListener == nil else { return }
        var address = Self.defaultInputDeviceAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { await self.scheduleRestart() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, defaultDeviceListenerQueue, listener
        )
        if status == noErr {
            defaultDeviceListener = listener
        }
    }

    private func installConfigurationObserverIfNeeded() {
        guard configurationObserver == nil else { return }
        // The engine stops itself when its input disappears or changes format: a pinned
        // mic that isn't the default gets unplugged, AirPods switch to HFP, another app
        // changes the sample rate, the Mac sleeps.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.scheduleRestart() }
        }
    }

    /// Engine-configuration and default-input notifications both land here; a burst
    /// of them is coalesced into one restart check.
    private func scheduleRestart() {
        // Idle: nothing to do, the next start() resolves the device anyway.
        guard engineCapture != nil else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.restartDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.restartIfNeeded()
        }
    }

    /// Reopens the input for the current recording, keeping what it captured, when
    /// the engine stopped (even on a pinned mic that is still connected) or its device
    /// is gone. A working mic is left alone: a new system default waits for the next
    /// recording, so connecting AirPods mid-sentence doesn't drop words.
    private func restartIfNeeded() {
        guard let capture = current, engineCapture === capture else { return }
        if engine.isRunning, activeDeviceID.map(AudioInputDeviceManager.isAlive) ?? true { return }

        capture.restarts += 1
        do {
            guard capture.restarts <= Self.maxRestartsPerRecording else {
                throw RecorderError.engineFailed("the input kept reconfiguring")
            }
            try startEngineOnBestDevice(feeding: capture)
            log.info("Capture restarted after an input change; kept \(capture.buffer.samples.count) samples")
        } catch {
            resetEngineHard()
            liveLevel = 0
            log.error("Recording died after an input change: \(String(describing: error), privacy: .public)")
            onRecordingFailed?("Microphone was disconnected")
        }
    }

    private func consume(chunk: [Float], level: Float, capture: Capture) {
        if capture === current {
            let attack: Float = 0.55
            let release: Float = 0.18
            let smoothing = level > liveLevel ? attack : release
            liveLevel += (level - liveLevel) * smoothing
        }
        guard !capture.meterOnly, !capture.limitTriggered, capture.buffer.append(chunk) else { return }
        capture.limitTriggered = true
        // A recording already being stopped just stops growing; stop() tears down.
        guard capture === current, engineCapture === capture else { return }
        stopEngine()
        liveLevel = 0
        onLimitReached?()
    }

    private final class ConverterBox: @unchecked Sendable {
        /// monoBuffer's per-channel energy. Only the tap block touches it, one buffer at a time.
        var channelEnergy: [Float] = []
        private let lock = NSLock()
        private var cachedConverter: AVAudioConverter?
        private var cachedSampleRate: Double = 0
        private var cachedChannels: AVAudioChannelCount = 0

        func converter(matching format: AVAudioFormat) -> AVAudioConverter? {
            lock.lock(); defer { lock.unlock() }
            guard let cached = cachedConverter,
                  cachedSampleRate == format.sampleRate,
                  cachedChannels == format.channelCount else { return nil }
            return cached
        }

        func store(converter: AVAudioConverter, format: AVAudioFormat) {
            lock.lock(); defer { lock.unlock() }
            cachedConverter = converter
            cachedSampleRate = format.sampleRate
            cachedChannels = format.channelCount
        }
    }

    private static func meterLevel(_ chunk: [Float], noiseFloor: Float, ceiling: Float) -> Float {
        guard !chunk.isEmpty else { return 0 }

        let meanSquare = chunk.reduce(Float.zero) { partial, sample in
            partial + (sample * sample)
        } / Float(chunk.count)
        let rms = sqrt(meanSquare)
        let peak = chunk.reduce(Float.zero) { max($0, abs($1)) }
        let combined = max(rms * 1.8, peak * 0.55)
        let normalized = max(0, min(1, (combined - noiseFloor) / max(ceiling - noiseFloor, 0.001)))

        // Lift conversational speech so the HUD reads as active without requiring clipping-level input.
        return pow(normalized, 0.65)
    }
}
