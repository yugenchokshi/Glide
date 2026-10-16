import Foundation
import Speech
import AVFoundation
import Observation

/// Optional on-device dictation for the task field (Speech framework). Only used when the
/// user enables voice input; microphone and speech permissions are requested on first use.
@MainActor
@Observable
final class VoiceInput {
    static let shared = VoiceInput()

    private(set) var isListening = false
    private(set) var error: String?
    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle(onText: @escaping (String) -> Void) {
        if isListening { stop() } else { Task { await start(onText: onText) } }
    }

    func start(onText: @escaping (String) -> Void) async {
        error = nil
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized else { error = "Speech recognition isn't allowed."; return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { error = "Microphone access isn't allowed."; return }
        guard let recognizer, recognizer.isAvailable else { error = "Dictation isn't available."; return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { self.error = error.localizedDescription; return }
        isListening = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                if let text { onText(text) }
                if err != nil || final { self?.stop() }
            }
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isListening = false
    }
}
