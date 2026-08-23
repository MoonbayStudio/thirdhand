import AVFoundation
import Speech
import SwiftUI

struct VoiceInputSettingsView: View {
    @AppStorage(AppPreferenceKeys.voiceInputEnabled)
    private var voiceInputEnabled = true
    @AppStorage(AppPreferenceKeys.voiceRecognitionLanguage)
    private var recognitionLanguage: VoiceRecognitionLanguage = .automatic
    @AppStorage(AppPreferenceKeys.voiceAddsPunctuation)
    private var addsPunctuation = true
    @AppStorage(AppPreferenceKeys.voicePrefersOnDeviceRecognition)
    private var prefersOnDeviceRecognition = true
    @AppStorage(AppPreferenceKeys.language)
    private var appLanguage: AppLanguage = .russian

    @State private var authorization = VoiceInputAuthorizationSnapshot.current
    @State private var isRequestingAuthorization = false

    var body: some View {
        WideSettingsLayout {
            WideSettingsSection {
                Toggle("Показывать микрофон в поле сообщения", isOn: $voiceInputEnabled)

                Picker("Язык распознавания", selection: $recognitionLanguage) {
                    ForEach(VoiceRecognitionLanguage.availableCases) { language in
                        Text(language.displayNameKey)
                            .tag(language)
                    }
                }

                if recognitionLanguage == .automatic {
                    HStack(spacing: 4) {
                        Text("Сейчас используется")
                        Text(activeLocaleDisplayName + ".")
                    }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Добавлять пунктуацию", isOn: $addsPunctuation)
                    .disabled(!voiceInputEnabled)
                Toggle("По возможности распознавать на Mac", isOn: $prefersOnDeviceRecognition)
                    .disabled(!voiceInputEnabled)
                Text("Нажмите микрофон в чате, продиктуйте сообщение и проверьте текст перед отправкой. При локальном распознавании рядом с записью появится значок Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            WideSettingsSection("Разрешения macOS") {
                VoicePermissionRow(
                    title: "Распознавание речи",
                    systemImage: "waveform",
                    status: speechPermissionTitle,
                    isAuthorized: authorization.speechRecognition == .authorized
                )
                VoicePermissionRow(
                    title: "Микрофон",
                    systemImage: "mic",
                    status: microphonePermissionTitle,
                    isAuthorized: authorization.microphone == .authorized
                )

                if !authorization.isAuthorized {
                    Button {
                        requestAuthorization()
                    } label: {
                        if isRequestingAuthorization {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Запросить доступ", systemImage: "checkmark.shield")
                        }
                    }
                    .disabled(isRequestingAuthorization || !voiceInputEnabled)
                    .accessibilityIdentifier("request-voice-permissions-button")
                }

                Text("Third Hand запрашивает доступ только после вашего действия. Если доступ уже запрещён, измените его в Системных настройках → Конфиденциальность и безопасность.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            authorization = .current
        }
    }

    private var activeLocaleDisplayName: String {
        let locale = recognitionLanguage.locale(appLanguage: appLanguage)
        return locale.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

    private var speechPermissionTitle: LocalizedStringKey {
        switch authorization.speechRecognition {
        case .authorized:
            "Разрешено"
        case .denied:
            "Запрещено"
        case .restricted:
            "Ограничено"
        case .notDetermined:
            "Ещё не запрошено"
        @unknown default:
            "Неизвестно"
        }
    }

    private var microphonePermissionTitle: LocalizedStringKey {
        switch authorization.microphone {
        case .authorized:
            "Разрешено"
        case .denied:
            "Запрещено"
        case .restricted:
            "Ограничено"
        case .notDetermined:
            "Ещё не запрошено"
        @unknown default:
            "Неизвестно"
        }
    }

    private func requestAuthorization() {
        isRequestingAuthorization = true
        Task {
            authorization = await VoiceInputController.requestAuthorization()
            isRequestingAuthorization = false
        }
    }
}

private struct VoicePermissionRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let status: LocalizedStringKey
    let isAuthorized: Bool

    var body: some View {
        LabeledContent {
            Label {
                Text(status)
            } icon: {
                Image(systemName: isAuthorized ? "checkmark.circle.fill" : "exclamationmark.circle")
            }
            .foregroundStyle(isAuthorized ? Color.green : Color.secondary)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityElement(children: .combine)
    }
}
