import AVFoundation

struct Microphone: Identifiable {
    let id: String
    let name: String

    static func available() -> [Microphone] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static var defaultName: String? { AVCaptureDevice.default(for: .audio)?.localizedName }
}

struct Wave {
    static let sampleRate: UInt32 = 16_000
    static let bytesPerSecond = Int(sampleRate) * 2
    static let maximumSeconds = 300

    static func trimSilence(from pcm: Data) -> Data {
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return pcm }
        let threshold: Int32 = 320 // ~ -40 dBFS
        let padSamples = Int(sampleRate) * 200 / 1000 // Keep 200ms natural speech padding

        var firstVoice = sampleCount
        var lastVoice = -1
        pcm.withUnsafeBytes { raw in
            for idx in 0..<sampleCount {
                let value = Int32(abs(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: idx * 2, as: Int16.self))))
                if value >= threshold {
                    if firstVoice == sampleCount { firstVoice = idx }
                    lastVoice = idx
                }
            }
        }
        guard lastVoice >= firstVoice else { return pcm }
        let start = max(0, firstVoice - padSamples)
        let end = min(sampleCount, lastVoice + 1 + padSamples)
        return pcm.subdata(in: (start * 2)..<(end * 2))
    }

    static func encode(pcm: Data) -> Data {
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }

        wav.reserveCapacity(44 + pcm.count)
        wav.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + pcm.count))
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // Linear PCM
        append(UInt16(1)) // Mono
        append(sampleRate)
        append(UInt32(bytesPerSecond))
        append(UInt16(2))
        append(UInt16(16))
        wav.append(contentsOf: "data".utf8)
        append(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}

struct RecordingWaveform: Sendable {
    let level: Double
    let samples: [Double]

    static func read(_ pcm: UnsafeRawBufferPointer) -> RecordingWaveform? {
        let frameCount = min(pcm.count / MemoryLayout<Int16>.size, 768)
        guard frameCount > 0 else { return nil }
        let firstFrame = pcm.count / MemoryLayout<Int16>.size - frameCount
        let pointCount = min(frameCount, 28)
        var squared = 0.0
        var peak = 0.0
        var points: [Double] = []
        points.reserveCapacity(pointCount)

        for point in 0..<pointCount {
            let start = firstFrame + point * frameCount / pointCount
            let end = firstFrame + (point + 1) * frameCount / pointCount
            var signedPeak = 0.0
            for frame in start..<end {
                let value = pcm.loadUnaligned(fromByteOffset: frame * 2, as: Int16.self)
                let sample = Double(Int16(littleEndian: value)) / 32_768
                squared += sample * sample
                if abs(sample) > abs(signedPeak) { signedPeak = sample }
            }
            peak = max(peak, abs(signedPeak))
            points.append(signedPeak)
        }

        let rms = (squared / Double(frameCount)).squareRoot()
        let decibels = 20 * log10(max(0.0001, rms))
        let gain = min(18, 0.92 / max(0.001, peak))
        return RecordingWaveform(
            level: min(1, max(0, (decibels + 56) / 50)),
            samples: points.map { $0 * gain }
        )
    }
}

final class AudioRecorder: @unchecked Sendable {
    // Session changes are confined to sessionQueue. The delegate only writes on sampleQueue.
    private let sessionQueue = DispatchQueue(label: "com.yapflush.audio.session", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "com.yapflush.audio.samples", qos: .userInitiated)
    private var active: Capture?

    func begin(
        id: UUID,
        deviceUID: String,
        onReady: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (VoiceTypeError) -> Void,
        onWaveform: @escaping @Sendable (RecordingWaveform) -> Void = { _ in }
    ) {
        sessionQueue.async {
            do {
                try self.start(id: id, deviceUID: deviceUID, onReady: onReady, onFailure: onFailure, onWaveform: onWaveform)
            } catch let error as VoiceTypeError {
                onFailure(error)
            } catch {
                onFailure(.message("无法打开麦克风。请检查连接，或在设置中选择其他输入。"))
            }
        }
    }

    func finish(id: UUID) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                guard let capture = self.stop(id: id) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let samples = self.sampleQueue.sync {
                    (capture.collector.pcm, capture.collector.invalidFormat, capture.collector.peakMagnitude)
                }
                if samples.1 {
                    continuation.resume(throwing: VoiceTypeError.message("无法转换麦克风音频格式。请尝试其他输入。"))
                } else if samples.0.count < Wave.bytesPerSecond / 6 {
                    continuation.resume(throwing: VoiceTypeError.message("录音太短或未收到音频。请按住快捷键再说话。"))
                } else if samples.2 < 260 {
                    continuation.resume(throwing: VoiceTypeError.message("未检测到声音。请确认麦克风未静音后再试。"))
                } else {
                    let trimmed = Wave.trimSilence(from: samples.0)
                    continuation.resume(returning: Wave.encode(pcm: trimmed))
                }
            }
        }
    }

    func cancel(id: UUID) {
        sessionQueue.async { _ = self.stop(id: id) }
    }

    private func start(
        id: UUID,
        deviceUID: String,
        onReady: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (VoiceTypeError) -> Void,
        onWaveform: @escaping @Sendable (RecordingWaveform) -> Void
    ) throws {
        guard active == nil else { throw VoiceTypeError.message("麦克风仍在结束上一段录音。请再试一次。") }
        let device = deviceUID.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: deviceUID)
        guard let device, device.isConnected else {
            throw VoiceTypeError.message("所选麦克风已断开。请重新连接，或在设置中更换输入。")
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Wave.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        guard session.canAddInput(input) else { throw VoiceTypeError.message("无法使用所选麦克风。") }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw VoiceTypeError.message("无法建立麦克风录音输出。") }
        let collector = Collector(onWaveform: onWaveform)
        output.setSampleBufferDelegate(collector, queue: sampleQueue)
        session.addOutput(output)

        let capture = Capture(id: id, session: session, output: output, collector: collector)
        active = capture
        let center = NotificationCenter.default
        capture.observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) {
                [weak self] _ in
                self?.interrupt(id: id, message: "麦克风录音中断。请检查输入后再试。", onFailure: onFailure)
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) {
                [weak self] _ in
                self?.interrupt(id: id, message: "录音时麦克风已断开。", onFailure: onFailure)
            }
        ]
        session.startRunning()
        guard session.isRunning else {
            _ = stop(id: id)
            throw VoiceTypeError.message("麦克风未能开始录音。请检查权限和所选输入。")
        }
        onReady(device.localizedName)
    }

    private func interrupt(id: UUID, message: String, onFailure: @escaping @Sendable (VoiceTypeError) -> Void) {
        sessionQueue.async {
            if self.stop(id: id) != nil { onFailure(.message(message)) }
        }
    }

    private func stop(id: UUID) -> Capture? {
        guard let capture = active, capture.id == id else { return nil }
        active = nil
        capture.observers.forEach(NotificationCenter.default.removeObserver)
        capture.session.stopRunning()
        capture.output.setSampleBufferDelegate(nil, queue: nil)
        return capture
    }

    private final class Capture {
        let id: UUID
        let session: AVCaptureSession
        let output: AVCaptureAudioDataOutput
        let collector: Collector
        var observers: [NSObjectProtocol] = []

        init(id: UUID, session: AVCaptureSession, output: AVCaptureAudioDataOutput, collector: Collector) {
            self.id = id
            self.session = session
            self.output = output
            self.collector = collector
        }
    }

    private final class Collector: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        var pcm = Data()
        var invalidFormat = false
        var peakMagnitude: Int32 = 0
        private let onWaveform: @Sendable (RecordingWaveform) -> Void
        private var lastWaveformAt: ContinuousClock.Instant?

        init(onWaveform: @escaping @Sendable (RecordingWaveform) -> Void) {
            self.onWaveform = onWaveform
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 16,
                  format.mChannelsPerFrame == 1, format.mBytesPerFrame == 2,
                  format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian) == 0,
                  format.mSampleRate == Double(Wave.sampleRate),
                  let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                invalidFormat = true
                return
            }

            let remaining = Wave.maximumSeconds * Wave.bytesPerSecond - pcm.count
            let length = min(CMBlockBufferGetDataLength(block), remaining)
            guard length > 0 else { return }
            let offset = pcm.count
            pcm.count += length
            let status = pcm.withUnsafeMutableBytes { buffer in
                let destination = buffer.baseAddress!.advanced(by: offset)
                let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: destination)
                if status == kCMBlockBufferNoErr {
                    let slice = UnsafeRawBufferPointer(start: destination, count: length)
                    updatePeak(in: slice)
                    measureWaveform(in: slice)
                }
                return status
            }
            if status != kCMBlockBufferNoErr {
                pcm.count = offset
                invalidFormat = true
            }
        }

        private func updatePeak(in samples: UnsafeRawBufferPointer) {
            let count = samples.count / MemoryLayout<Int16>.size
            var localPeak = peakMagnitude
            for idx in stride(from: 0, to: count, by: 4) {
                let raw = Int16(littleEndian: samples.loadUnaligned(fromByteOffset: idx * 2, as: Int16.self))
                let mag = abs(Int32(raw))
                if mag > localPeak { localPeak = mag }
            }
            peakMagnitude = localPeak
        }

        private func measureWaveform(in samples: UnsafeRawBufferPointer) {
            let now = ContinuousClock.now
            if let lastWaveformAt, lastWaveformAt.duration(to: now) < .milliseconds(35) { return }
            lastWaveformAt = now
            if let waveform = RecordingWaveform.read(samples) { onWaveform(waveform) }
        }
    }
}
