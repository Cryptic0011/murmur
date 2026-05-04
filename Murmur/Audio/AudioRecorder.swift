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
    private var isRecording = false
    private var limitTriggered = false
    private var tapInstalled = false
    private var defaultDeviceListenerInstalled = false
    var onLimitReached: (@Sendable () -> Void)?

    func setOnLimitReached(_ callback: (@Sendable () -> Void)?) {
        onLimitReached = callback
    }

    func start(maxSeconds: Int) throws {
        self.maxSeconds = maxSeconds
        self.buffer = AudioBuffer(maxSamples: Int(sampleRate) * maxSeconds)
        self.liveLevel = 0
        self.limitTriggered = false
        self.isRecording = false

        installDefaultDeviceListenerIfNeeded()

        do {
            try startEngineForCurrentDefaultDevice()
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

    private func startEngineForCurrentDefaultDevice() throws {
        guard var deviceID = AudioInputDeviceManager.systemDefaultInputDeviceID() else {
            try startEngineForCurrentDevice(overrideDevice: false)
            return
        }
        try startEngineForCurrentDevice(overrideDevice: false, forcedDeviceID: &deviceID)
    }

    private func startEngineForDevice(_ deviceID: AudioDeviceID?) throws {
        guard var deviceID else {
            try startEngineForCurrentDevice(overrideDevice: false)
            return
        }
        try startEngineForCurrentDevice(overrideDevice: false, forcedDeviceID: &deviceID)
    }

    private func startEngineForCurrentDevice(
        overrideDevice: Bool = false,
        forcedDeviceID: UnsafeMutablePointer<AudioDeviceID>? = nil
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

    func stop() -> [Float] {
        if isRecording {
            removeTapIfInstalled()
            engine.stop()
            isRecording = false
        }
        return buffer.samples
    }

    func currentLevel() -> Float { liveLevel }
    func didOverflow() -> Bool { buffer.didOverflow }

    private func configureTap() throws {
        let input = engine.inputNode
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw RecorderError.conversionFailed }

        let converterBox = ConverterBox()

        removeTapIfInstalled()
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] pcm, _ in
            guard let self else { return }
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
            converter.convert(to: outBuf, error: &error) { _, status in
                status.pointee = .haveData
                return pcm
            }
            if error != nil { return }
            let count = Int(outBuf.frameLength)
            guard let channel = outBuf.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
            let level = Self.meterLevel(chunk, noiseFloor: self.inputNoiseFloor, ceiling: self.inputCeiling)
            Task { await self.consume(chunk: chunk, level: level) }
        }
        tapInstalled = true
    }

    private func removeTapIfInstalled() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func applyCurrentInputDevice() {
        guard var deviceID = AudioInputDeviceManager.systemDefaultInputDeviceID() else { return }
        applyInputDevice(&deviceID)
    }

    private func applyInputDevice(_ deviceID: UnsafeMutablePointer<AudioDeviceID>) {
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        _ = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            deviceID,
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
            try startEngineForCurrentDefaultDevice()
            isRecording = true
        } catch {
            resetEngineHard()
            do {
                try startEngineForCurrentDevice(overrideDevice: true)
                isRecording = true
            } catch {
                isRecording = false
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
