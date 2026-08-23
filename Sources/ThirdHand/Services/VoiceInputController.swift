@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

struct VoiceInputConfiguration: Sendable, Equatable {
    let localeIdentifier: String
    let addsPunctuation: Bool
    let prefersOnDeviceRecognition: Bool
}

struct VoiceInputAuthorizationSnapshot: Equatable {
    let speechRecognition: SFSpeechRecognizerAuthorizationStatus
    let microphone: AVAuthorizationStatus

    static var current: Self {
        Self(
            speechRecognition: SFSpeechRecognizer.authorizationStatus(),
            microphone: AVCaptureDevice.authorizationStatus(for: .audio)
        )
    }

    var isAuthorized: Bool {
        speechRecognition == .authorized && microphone == .authorized
    }
}

enum VoiceInputFailure: LocalizedError, Equatable {
    case speechPermissionDenied
    case speechPermissionRestricted
    case microphonePermissionDenied
    case microphonePermissionRestricted
    case recognizerUnavailable
    case noAudioInput
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            AppLocalization.string(
                "Доступ к распознаванию речи запрещён. Разрешите его в настройках конфиденциальности macOS."
            )
        case .speechPermissionRestricted:
            AppLocalization.string("Распознавание речи ограничено на этом Mac.")
        case .microphonePermissionDenied:
            AppLocalization.string(
                "Доступ к микрофону запрещён. Разрешите его в настройках конфиденциальности macOS."
            )
        case .microphonePermissionRestricted:
            AppLocalization.string("Доступ к микрофону ограничен на этом Mac.")
        case .recognizerUnavailable:
            AppLocalization.string(
                "Распознавание речи для выбранного языка сейчас недоступно."
            )
        case .noAudioInput:
            AppLocalization.string("Third Hand не нашёл доступный аудиовход.")
        case let .couldNotStart(message):
            String(
                format: AppLocalization.string("Не удалось начать голосовой ввод: %@"),
                locale: AppLocalization.language.locale,
                message
            )
        }
    }
}

@MainActor
@Observable
final class VoiceInputController {
    private(set) var transcript = ""
    private(set) var isRecording = false
    private(set) var errorMessage: String?
    private(set) var usesOnDeviceRecognition = false

    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var inputTapIsInstalled = false

    func start(configuration: VoiceInputConfiguration) async {
        guard !isRecording else { return }

        cancel()
        transcript = ""
        errorMessage = nil

        let authorization = await Self.requestAuthorization()
        guard authorization.speechRecognition == .authorized else {
            fail(with: speechFailure(for: authorization.speechRecognition))
            return
        }
        guard authorization.microphone == .authorized else {
            fail(with: microphoneFailure(for: authorization.microphone))
            return
        }

        let locale = Locale(identifier: configuration.localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            fail(with: .recognizerUnavailable)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = configuration.addsPunctuation

        usesOnDeviceRecognition = configuration.prefersOnDeviceRecognition
            && recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = usesOnDeviceRecognition

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            fail(with: .noAudioInput)
            return
        }

        speechRecognizer = recognizer
        recognitionRequest = request

        Self.installInputTap(
            on: inputNode,
            format: recordingFormat,
            request: request
        )
        inputTapIsInstalled = true

        recognizer.queue = .main
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let recognizedText = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDescription = error?.localizedDescription

            Task { @MainActor [weak self] in
                self?.handleRecognitionResult(
                    text: recognizedText,
                    isFinal: isFinal,
                    errorDescription: errorDescription
                )
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            cancel()
            fail(with: .couldNotStart(error.localizedDescription))
        }
    }

    func stop() {
        stopAudioCapture()
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        isRecording = false
    }

    func cancel() {
        stopAudioCapture()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        isRecording = false
        usesOnDeviceRecognition = false
    }

    func clearTranscript() {
        transcript = ""
    }

    static func requestAuthorization() async -> VoiceInputAuthorizationSnapshot {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            speechStatus = await requestSpeechAuthorization()
        case let status:
            speechStatus = status
        }

        let microphoneStatus: AVAuthorizationStatus
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            let granted = await requestMicrophoneAuthorization()
            microphoneStatus = granted ? .authorized : .denied
        case let status:
            microphoneStatus = status
        }

        return VoiceInputAuthorizationSnapshot(
            speechRecognition: speechStatus,
            microphone: microphoneStatus
        )
    }

    // TCC invokes both permission callbacks on an arbitrary queue. Keep the
    // continuation bridges nonisolated so Swift 6 does not inherit this
    // @MainActor type's executor for callbacks that are not delivered on it.
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private nonisolated static func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // AVAudioEngine runs tap callbacks on its real-time audio queue. Form the
    // callback outside MainActor isolation so Swift does not assert that this
    // framework-owned queue must be the main queue.
    private nonisolated static func installInputTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format
        ) { [weak request] buffer, _ in
            request?.append(buffer)
        }
    }

    private func handleRecognitionResult(
        text: String?,
        isFinal: Bool,
        errorDescription: String?
    ) {
        if let text, !text.isEmpty {
            transcript = text
        }

        if let errorDescription, !isFinal {
            cancel()
            errorMessage = String(
                format: AppLocalization.string("Голосовой ввод остановлен: %@"),
                locale: AppLocalization.language.locale,
                errorDescription
            )
            return
        }

        if isFinal {
            stop()
        }
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if inputTapIsInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapIsInstalled = false
        }
        recognitionRequest?.endAudio()
    }

    private func fail(with failure: VoiceInputFailure) {
        errorMessage = failure.localizedDescription
        isRecording = false
    }

    private func speechFailure(
        for status: SFSpeechRecognizerAuthorizationStatus
    ) -> VoiceInputFailure {
        status == .restricted ? .speechPermissionRestricted : .speechPermissionDenied
    }

    private func microphoneFailure(
        for status: AVAuthorizationStatus
    ) -> VoiceInputFailure {
        status == .restricted ? .microphonePermissionRestricted : .microphonePermissionDenied
    }
}
