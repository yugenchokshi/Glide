import AVFoundation
import Speech
import os

/// On-device speech recognition: SpeechAnalyzer + SpeechTranscriber (macOS 26), falling back to
/// SFSpeechRecognizer with on-device recognition required. Audio never leaves the Mac and is
/// never stored; only the transcript is handed on.
///
/// The microphone runs only between `start` and the end of the utterance (or `stop`). End of
/// speech is decided by `EndOfSpeechDetector` on the audio thread: the transcriber's finalized
/// result plus ~0.8 s of trailing silence, capped at 30 s.
@MainActor
final class OnDeviceRecognizer: VoiceRecognizer {
    var onEvent: ((ListenEvent) -> Void)?

    private let audio: VoiceAudio
    private var generation = 0
    private var runTask: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var tap: MicTap?
    private var transcript = Transcript()
    private var ending = false
    // SpeechAnalyzer path.
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    // SFSpeechRecognizer path.
    private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?
    private var legacyFinal: CheckedContinuation<Void, Never>?

    /// The one-time download of the transcriber's language assets, shared by every listen.
    private static var install: Task<Bool, Never>?
    private static var installFraction: Double?

    static let micOffMessage = "Glide can't hear you yet. Turn on the microphone for Glide in System Settings › Privacy & Security › Microphone."
    private var log: Logger { Logger(subsystem: "dev.glide", category: "voice") }

    init(audio: VoiceAudio = .shared) {
        self.audio = audio
    }

    func start(_ request: ListenRequest) {
        stop()
        generation += 1
        let gen = generation
        runTask = Task { await self.run(request, gen) }
    }

    func stop() {
        generation += 1
        runTask?.cancel()
        runTask = nil
        teardown()
    }

    private func emit(_ event: ListenEvent, _ gen: Int) {
        guard gen == generation else { return }
        onEvent?(event)
    }

    private struct Transcript {
        var finalized = ""
        var volatile = ""
        var full: String { VoiceSession.join(finalized, volatile) }
    }

    private enum Backend {
        case analyzer(SpeechTranscriber)
        case legacy(SFSpeechRecognizer)
        case unavailable(String)
    }

    // MARK: Run

    private func run(_ request: ListenRequest, _ gen: Int) async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard request.mayPrompt, await AVCaptureDevice.requestAccess(for: .audio) else { return emit(.failed(Self.micOffMessage), gen) }
        default: return emit(.failed(Self.micOffMessage), gen)
        }
        guard gen == generation else { return }
        let backend = await chooseBackend(request, gen)
        guard gen == generation else { return }
        do {
            switch backend {
            case .analyzer(let transcriber): try await startAnalyzer(transcriber, request, gen)
            case .legacy(let recognizer): try startLegacy(recognizer, request, gen)
            case .unavailable(let message): return emit(.failed(message), gen)
            }
        } catch {
            guard gen == generation else { return }
            log.error("listening failed: \(String(describing: error), privacy: .public)")
            teardown()
            emit(.failed("Glide couldn't start listening. Try again, or type your request."), gen)
        }
    }

    /// SpeechTranscriber when its assets are installed. The first time, they download in the
    /// background while SFSpeechRecognizer listens; if it can't, the notch shows the progress.
    private func chooseBackend(_ request: ListenRequest, _ gen: Int) async -> Backend {
        let locale = Locale.current
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = Self.makeTranscriber(supported)
            let status = await AssetInventory.status(forModules: [transcriber])
            if status == .installed { return .analyzer(transcriber) }
            if status != .unsupported {
                let install = Self.installAssets(for: transcriber)
                if let legacy = await legacyRecognizer(locale, request) { return .legacy(legacy) }
                while gen == generation {
                    emit(.preparing(Self.installFraction), gen)
                    if let done = await Self.finished(install, within: 0.25) {
                        if done { return .analyzer(Self.makeTranscriber(supported)) }
                        break
                    }
                }
            }
        }
        if let legacy = await legacyRecognizer(locale, request) { return .legacy(legacy) }
        let language = locale.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "") ?? "your language"
        return .unavailable("On-device speech recognition isn't available for \(language) on this Mac. You can type instead.")
    }

    static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    private func legacyRecognizer(_ locale: Locale, _ request: ListenRequest) async -> SFSpeechRecognizer? {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else { return nil }
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined && request.mayPrompt {
            status = await Self.requestSpeechAuthorization()
        }
        return status == .authorized ? recognizer : nil
    }

    private static func installAssets(for transcriber: SpeechTranscriber) -> Task<Bool, Never> {
        if let install { return install }
        let task = Task { @MainActor () -> Bool in
            do {
                _ = try? await AssetInventory.reserve(locale: transcriber.selectedLocales.first ?? Locale.current)
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return true }
                let progress = request.progress
                let poll = Task { @MainActor in
                    while !Task.isCancelled {
                        installFraction = progress.fractionCompleted
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                defer { poll.cancel() }
                try await request.downloadAndInstall()
                return true
            } catch {
                Logger(subsystem: "dev.glide", category: "voice").error("speech assets: \(String(describing: error), privacy: .public)")
                OnDeviceRecognizer.install = nil
                return false
            }
        }
        install = task
        return task
    }

    /// The task's result if it finishes within `seconds`, else nil.
    private static func finished(_ task: Task<Bool, Never>, within seconds: Double) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: SpeechAnalyzer

    private func startAnalyzer(_ transcriber: SpeechTranscriber, _ request: ListenRequest, _ gen: Int) async throws {
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        try await analyzer.prepareToAnalyze(in: format)
        guard gen == generation else { await analyzer.cancelAndFinishNow(); return }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.analyzer = analyzer
        self.input = continuation
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.took(text: String(result.text.characters), isFinal: result.isFinal, gen)
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
        guard gen == generation else { return }
        try openMic(request, analyzerFormat: format, gen) { buffer in continuation.yield(AnalyzerInput(buffer: buffer)) }
    }

    private func took(text: String, isFinal: Bool, _ gen: Int) {
        guard gen == generation else { return }
        if isFinal {
            transcript.finalized = VoiceSession.join(transcript.finalized, text)
            transcript.volatile = ""
        } else {
            transcript.volatile = text
        }
        let full = transcript.full
        // Quiet speech the level detector missed still counts once there are words.
        if !full.isEmpty { tap?.noteSpeech() }
        tap?.setSettled(transcript.volatile.isEmpty && !transcript.finalized.isEmpty)
        if !ending { emit(.partial(full), gen) }
    }

    // MARK: SFSpeechRecognizer

    private func startLegacy(_ recognizer: SFSpeechRecognizer, _ request: ListenRequest, _ gen: Int) throws {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.taskHint = .dictation
        legacyRequest = req
        legacyTask = Self.recognitionTask(recognizer, req) { [weak self] text, isFinal, failed in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if let text {
                    self.transcript.volatile = text
                    if !text.isEmpty { self.tap?.noteSpeech() }
                    if !self.ending { self.emit(.partial(text), gen) }
                }
                if isFinal || failed {
                    self.legacyFinal?.resume()
                    self.legacyFinal = nil
                }
            }
        }
        // Appending from the audio thread is how the request is meant to be fed.
        let feed = UncheckedBox(req)
        try openMic(request, analyzerFormat: nil, gen) { buffer in feed.value.append(buffer) }
        // SFSpeechRecognizer only finalizes at the end of audio, so silence alone ends it.
        tap?.setSettled(true)
    }

    /// Nonisolated so the result handler (called on the recognizer's queue) isn't tied to the main actor.
    nonisolated private static func recognitionTask(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                                    handler: @escaping @Sendable (String?, Bool, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
    }

    // MARK: Microphone

    private func openMic(_ request: ListenRequest, analyzerFormat: AVAudioFormat?, _ gen: Int,
                         sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if request.echoCancellation {
            try inputNode.setVoiceProcessingEnabled(true)
            // Keep the user's other audio at its volume while Glide listens.
            inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            _ = engine.mainMixerNode
        }
        let micFormat = inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw SpeechClientError.badURL }
        var config = EndOfSpeechDetector.Config()
        config.noSpeechTimeout = request.noSpeechTimeout
        config.maxUtterance = request.maxUtterance
        let tap = try MicTap(micFormat: micFormat, outputFormat: analyzerFormat, config: config, sink: sink,
                             onLevel: { [weak self] level in Task { @MainActor in self?.emit(.level(level), gen) } },
                             onDetector: { [weak self] event in Task { @MainActor in self?.detector(event, gen) } })
        self.tap = tap
        Self.install(tap, on: inputNode, format: micFormat)
        engine.prepare()
        try engine.start()
        self.engine = engine
        audio.registerInput(engine, echoCancelled: request.echoCancellation)
        emit(.started, gen)
    }

    /// Nonisolated so the tap block (run on the audio thread) isn't tied to the main actor.
    nonisolated private static func install(_ tap: MicTap, on node: AVAudioInputNode, format: AVAudioFormat) {
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in tap.process(buffer) }
    }

    private func detector(_ event: EndOfSpeechDetector.Event, _ gen: Int) {
        guard gen == generation, !ending else { return }
        switch event {
        case .speechStarted: emit(.speechStarted, gen)
        case .endOfSpeech, .maxLength: endpoint(gen)
        case .noSpeech:
            if transcript.full.isEmpty {
                teardown()
                emit(.noSpeech, gen)
            } else {
                endpoint(gen)
            }
        }
    }

    /// The user finished: the microphone closes at once, then the transcriber finalizes what it
    /// heard and the final text goes out.
    private func endpoint(_ gen: Int) {
        guard !ending else { return }
        ending = true
        closeMic()
        input?.finish()
        legacyRequest?.endAudio()
        Task {
            if let analyzer {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                if let results = resultsTask { _ = await Self.finished(Task { await results.value; return true }, within: 1.5) }
            } else if legacyTask != nil {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    legacyFinal = c
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        self.legacyFinal?.resume()
                        self.legacyFinal = nil
                    }
                }
            }
            guard gen == generation else { return }
            let text = transcript.full
            teardown()
            emit(.finished(text), gen)
        }
    }

    private func closeMic() {
        if let engine {
            audio.closeInput(engine)
            self.engine = nil
        }
        tap = nil
    }

    private func teardown() {
        closeMic()
        input?.finish()
        input = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
            self.analyzer = nil
        }
        legacyTask?.cancel()
        legacyTask = nil
        legacyRequest = nil
        legacyFinal?.resume()
        legacyFinal = nil
        transcript = Transcript()
        ending = false
    }

    // MARK: Files (tests, diagnostics)

    /// Transcribes an audio file on device with SpeechTranscriber. Nil when the transcriber or
    /// its assets for `locale` aren't installed (nothing is downloaded).
    static func transcribe(file url: URL, locale: Locale = Locale(identifier: "en-US")) async throws -> String? {
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { return nil }
        let file = try AVAudioFile(forReading: url)
        let collect = Task { () -> String in
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text = VoiceSession.join(text, String(result.text.characters))
            }
            return text
        }
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collect.value
    }
}

/// Hands a thread-safe framework object to the audio thread.
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Runs on the audio thread for every microphone buffer: level, end-of-speech detection, and
/// conversion to the transcriber's format. The detector is the only state, behind a lock (the
/// main actor tells it when the transcript is settled).
final class MicTap: @unchecked Sendable {
    private let lock = NSLock()
    private var detector: EndOfSpeechDetector
    private let monoFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat?
    private let converter: AVAudioConverter?
    private let sink: @Sendable (AVAudioPCMBuffer) -> Void
    private let onLevel: @Sendable (Float) -> Void
    private let onDetector: @Sendable (EndOfSpeechDetector.Event) -> Void
    private var levelTick = 0

    init(micFormat: AVAudioFormat, outputFormat: AVAudioFormat?, config: EndOfSpeechDetector.Config,
         sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onLevel: @escaping @Sendable (Float) -> Void,
         onDetector: @escaping @Sendable (EndOfSpeechDetector.Event) -> Void) throws {
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: micFormat.sampleRate, channels: 1, interleaved: false) else {
            throw SpeechClientError.badURL
        }
        monoFormat = mono
        self.outputFormat = outputFormat
        converter = outputFormat.flatMap { $0 == mono ? nil : AVAudioConverter(from: mono, to: $0) }
        detector = EndOfSpeechDetector(config: config)
        self.sink = sink
        self.onLevel = onLevel
        self.onDetector = onDetector
    }

    func setSettled(_ settled: Bool) { lock.withLock { detector.transcriptSettled = settled } }
    func noteSpeech() { lock.withLock { detector.noteSpeech() } }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let mono = Self.firstChannel(buffer, format: monoFormat) else { return }
        let db = EndOfSpeechDetector.levelDB(mono)
        let duration = Double(mono.frameLength) / monoFormat.sampleRate
        let event = lock.withLock { detector.process(levelDB: db, duration: duration) }
        levelTick += 1
        if levelTick % 2 == 0 { onLevel(EndOfSpeechDetector.displayLevel(db: db)) }
        if let event { onDetector(event) }
        if let converter, let outputFormat {
            if let converted = Self.convert(mono, with: converter, to: outputFormat) { sink(converted) }
        } else {
            sink(mono)
        }
    }

    /// Channel 0 as a mono float buffer (voice-processing input can have several channels).
    static func firstChannel(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let n = buffer.frameLength
        guard n > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n), let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = n
        if let src = buffer.floatChannelData {
            let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
            for i in 0..<Int(n) { dst[i] = src[0][i * stride] }
        } else if let src = buffer.int16ChannelData {
            let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
            for i in 0..<Int(n) { dst[i] = Float(src[0][i * stride]) / 32768 }
        } else {
            return nil
        }
        return out
    }

    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}
