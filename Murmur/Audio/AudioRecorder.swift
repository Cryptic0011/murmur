import AVFoundation
import CoreAudio
import OSLog

actor AudioRecorder {
    enum RecorderError: Error, LocalizedError {
        case engineFailed(String)
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .engineFailed(let detail): return "Audio engine failed: \(detail)"
            case .conversionFailed: return "Audio conversion setup failed."
            }
        }
    }

    private let log = Logger(subsystem: "com.murmur.app", category: "audio-recorder")

    private let engine = AVAudioEngine()
    private var buffer = AudioBuffer(maxSamples: 16_000 * 60)
    private var liveLevel: Float = 0
    private let inputNoiseFloor: Float = 0.015
    private let inputCeiling: Float = 0.18
    private var sampleRate: Double = 16_000
    private var maxSeconds: Int = 60
    /// When set, records from this device (if connected) instead of the system default.
    private var preferredDeviceUID: String?
    private var isRecording = false
    private var limitTriggered = false
    private var tapInstalled = false
    private var defaultDeviceListenerInstalled = false
    // Tap callbacks run on the audio render thread; yielding into this stream keeps
    // chunks strictly ordered, and one consumer task appends them to the buffer.
    private var chunkContinuation: AsyncStream<([Float], Float)>.Continuation?
    private var consumeTask: Task<Void, Never>?
    var onLimitReached: (@Sendable () -> Void)?
    /// Recording died mid-session (e.g. device unplug and restart failed) —
    /// without this the HUD keeps showing "recording" over a dead mic.
    var onRecordingFailed: (@Sendable (String) -> Void)?

    func setOnLimitReached(_ callback: (@Sendable () -> Void)?) {
        onLimitReached = callback
    }

    func setOnRecordingFailed(_ callback: (@Sendable (String) -> Void)?) {
        onRecordingFailed = callback
    }

    func start(maxSeconds: Int, preferredDeviceUID: String? = nil) throws {
        self.maxSeconds = maxSeconds
        self.preferredDeviceUID = preferredDeviceUID
        self.buffer = AudioBuffer(maxSamples: Int(sampleRate) * maxSeconds)
        self.liveLevel = 0
        self.limitTriggered = false
        self.isRecording = false

        chunkContinuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: ([Float], Float).self)
        chunkContinuation = continuation
        consumeTask = Task { [weak self] in
            for await (chunk, level) in stream {
                await self?.consume(chunk: chunk, level: level)
            }
        }

        installDefaultDeviceListenerIfNeeded()

        do {
            try startEngineForPreferredOrDefaultDevice()
        } catch {
            log.error("Mic start (system default) failed: \(String(describing: error), privacy: .public)")
            resetEngineHard()
            do {
                try startEngineForCurrentDevice(overrideDevice: false)
            } catch {
                log.error("Mic start (input node default) failed: \(String(describing: error), privacy: .public)")
                resetEngineHard()
                do {
                    try startEngineForDevice(Self.builtInInputDeviceID())
                } catch {
                    log.error("Mic start (built-in fallback) failed: \(String(describing: error), privacy: .public)")
                    throw error
                }
            }
        }
        isRecording = true
    }

    private func startEngineForPreferredOrDefaultDevice() throws {
        if let uid = preferredDeviceUID,
           let deviceID = AudioInputDeviceManager.deviceID(forUID: uid)
        {
            try startEngineForCurrentDevice(overrideDevice: false, forcedDeviceID: deviceID)
            return
        }
        // Preferred mic not connected (or none chosen) — follow the system default.
        try startEngineForCurrentDefaultDevice()
    }

    private func startEngineForCurrentDefaultDevice() throws {
        try startEngineForCurrentDevice(
            overrideDevice: false,
            forcedDeviceID: AudioInputDeviceManager.systemDefaultInputDeviceID()
        )
    }

    private func startEngineForDevice(_ deviceID: AudioDeviceID?) throws {
        try startEngineForCurrentDevice(overrideDevice: false, forcedDeviceID: deviceID)
    }

    private func startEngineForCurrentDevice(
        overrideDevice: Bool = false,
        forcedDeviceID: AudioDeviceID? = nil
    ) throws {
        removeTapIfInstalled()
        if engine.isRunning { engine.stop() }
        engine.reset()

        if let forcedDeviceID {
            applyInputDevice(forcedDeviceID)
        } else if overrideDevice {
            applyCurrentInputDevice()
        }

        do {
            try configureTap()
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
    }

    private func resetEngineHard() {
        removeTapIfInstalled()
        if engine.isRunning { engine.stop() }
        engine.reset()
    }

    func stop() async -> [Float] {
        if isRecording {
            removeTapIfInstalled()
            engine.stop()
        }
        // Drain in-flight chunks before snapshotting, or the tail of the last word
        // (anything yielded but not yet consumed) is silently dropped.
        chunkContinuation?.finish()
        chunkContinuation = nil
        await consumeTask?.value
        consumeTask = nil
        isRecording = false
        return buffer.samples
    }

    func currentLevel() -> Float { liveLevel }
    func didOverflow() -> Bool { buffer.didOverflow }
    func currentSampleCount() -> Int { buffer.samples.count }
    func currentSamples() -> [Float] { buffer.samples }

    private func configureTap() throws {
        let input = engine.inputNode
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw RecorderError.conversionFailed }

        let converterBox = ConverterBox()
        let continuation = chunkContinuation
        let noiseFloor = inputNoiseFloor
        let ceiling = inputCeiling

        removeTapIfInstalled()
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { pcm, _ in
            let inputFormat = pcm.format
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }

            let converter: AVAudioConverter
            if let cached = converterBox.converter(matching: inputFormat) {
                converter = cached
            } else {
                guard let made = AVAudioConverter(from: inputFormat, to: targetFormat) else { return }
                converterBox.store(converter: made, format: inputFormat)
                converter = made
            }

            let frameCapacity = AVAudioFrameCount(
                max(1.0, targetFormat.sampleRate * Double(pcm.frameLength) / inputFormat.sampleRate)
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
                return pcm
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

    private func removeTapIfInstalled() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func applyCurrentInputDevice() {
        guard let deviceID = AudioInputDeviceManager.systemDefaultInputDeviceID() else { return }
        applyInputDevice(deviceID)
    }

    private func applyInputDevice(_ deviceID: AudioDeviceID) {
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        var deviceID = deviceID
        _ = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private static func builtInInputDeviceID() -> AudioDeviceID? {
        var size: UInt32 = 0
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size
        ) == noErr, size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &ids
        ) == noErr else { return nil }

        for id in ids {
            // Must have input streams
            var streamsSize: UInt32 = 0
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0 else { continue }

            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            var tAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport) == noErr else { continue }
            if transport == kAudioDeviceTransportTypeBuiltIn {
                return id
            }
        }
        return nil
    }

    private func installDefaultDeviceListenerIfNeeded() {
        guard !defaultDeviceListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated)
        ) { [weak self] _, _ in
            guard let self else { return }
            Task { await self.handleDefaultInputDeviceChanged() }
        }
        if status == noErr {
            defaultDeviceListenerInstalled = true
        }
    }

    private func handleDefaultInputDeviceChanged() async {
        // Pinned to a specific mic that's still connected — a change to the *system
        // default* input is irrelevant, and restarting would drop words mid-capture.
        if isRecording, let uid = preferredDeviceUID,
           AudioInputDeviceManager.deviceID(forUID: uid) != nil {
            return
        }

        let wasRecording = isRecording
        if wasRecording {
            removeTapIfInstalled()
            engine.stop()
            isRecording = false
        }

        guard wasRecording else {
            applyCurrentInputDevice()
            return
        }

        do {
            try startEngineForPreferredOrDefaultDevice()
            isRecording = true
        } catch {
            resetEngineHard()
            do {
                try startEngineForCurrentDevice(overrideDevice: true)
                isRecording = true
            } catch {
                isRecording = false
                log.error("Recording died after input device change: \(String(describing: error), privacy: .public)")
                onRecordingFailed?("Microphone was disconnected")
            }
        }
    }

    private func consume(chunk: [Float], level: Float) {
        guard isRecording else { return }
        let attack: Float = 0.55
        let release: Float = 0.18
        let smoothing = level > liveLevel ? attack : release
        liveLevel += (level - liveLevel) * smoothing
        let didOverflow = buffer.append(chunk)
        if didOverflow && !limitTriggered {
            limitTriggered = true
            removeTapIfInstalled()
            engine.stop()
            isRecording = false
            onLimitReached?()
        }
    }

    private final class ConverterBox: @unchecked Sendable {
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
