import AppKit
import SwiftUI

struct OnboardingView: View {
    private enum Step: Int, CaseIterable {
        case preferences
        case animation
    }

    @Environment(\.appAccessibilityOptions) private var accessibilityOptions
    @State private var step: Step = .preferences

    let onComplete: () -> Void

    var body: some View {
        ZStack {
            OnboardingBackdrop()

            VStack(spacing: 0) {
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(step)
                    .transition(stepTransition)

                OnboardingFooter(
                    currentStep: step.rawValue,
                    stepCount: Step.allCases.count,
                    showsBackButton: step != .preferences,
                    onBack: showPreviousStep,
                    onContinue: continueOnboarding
                )
            }
        }
        .background(MacWindowChromeConfigurator(title: "Third Hand"))
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .preferences:
            OnboardingPreferencesStep()
        case .animation:
            OnboardingAnimationStep()
        }
    }

    private var stepTransition: AnyTransition {
        guard !accessibilityOptions.reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private func showPreviousStep() {
        guard step == .animation else { return }
        updateStep(.preferences)
    }

    private func continueOnboarding() {
        switch step {
        case .preferences:
            updateStep(.animation)
        case .animation:
            onComplete()
        }
    }

    private func updateStep(_ newStep: Step) {
        withAnimation(
            accessibilityOptions.reduceMotion
                ? nil
                : .easeInOut(duration: 0.34)
        ) {
            step = newStep
        }
    }
}

private struct OnboardingBackdrop: View {
    @Environment(\.appAccessibilityOptions) private var accessibilityOptions

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            if !accessibilityOptions.reduceTransparency {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.16),
                        Color.purple.opacity(0.08),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingPreferencesStep: View {
    @AppStorage(AppPreferenceKeys.language)
    private var language: AppLanguage = .russian
    @AppStorage(AppPreferenceKeys.reduceMotion)
    private var additionallyReduceMotion = false
    @AppStorage(AppPreferenceKeys.reduceTransparency)
    private var additionallyReduceTransparency = false
    @AppStorage(AppPreferenceKeys.differentiateWithoutColor)
    private var additionallyDifferentiateWithoutColor = false
    @AppStorage(AppPreferenceKeys.increaseContrast)
    private var additionallyIncreaseContrast = false
    @AppStorage(AppPreferenceKeys.textSize)
    private var textSize: AppAccessibilityTextSize = .standard

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var systemDifferentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var systemColorSchemeContrast

    var body: some View {
        ScrollView {
            HStack(alignment: .center, spacing: 64) {
                welcome
                    .frame(width: 320, alignment: .leading)

                preferences
                    .frame(maxWidth: 520)
            }
            .frame(maxWidth: 940)
            .padding(.horizontal, 48)
            .padding(.top, 76)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                Text("Добро пожаловать в Third Hand")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text("Сначала настройте язык и доступность. Всё это можно изменить позже.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 0) {
            preferenceSection(
                title: "Язык интерфейса",
                systemImage: "globe"
            ) {
                Picker("Язык интерфейса", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayNameKey)
                            .tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 230, alignment: .trailing)
                .accessibilityIdentifier("onboarding-language-picker")
            }

            Divider()
                .padding(.vertical, 18)

            VStack(alignment: .leading, spacing: 14) {
                Label("Универсальный доступ", systemImage: "accessibility")
                    .font(.headline)

                OnboardingAccessibilityToggle(
                    title: "Уменьшение движения",
                    systemImage: "figure.walk.motion",
                    isEnabledInSystem: systemReduceMotion,
                    isAdditionallyEnabled: $additionallyReduceMotion
                )
                OnboardingAccessibilityToggle(
                    title: "Уменьшение прозрачности",
                    systemImage: "circle.dotted.circle",
                    isEnabledInSystem: systemReduceTransparency,
                    isAdditionallyEnabled: $additionallyReduceTransparency
                )
                OnboardingAccessibilityToggle(
                    title: "Различение без цвета",
                    systemImage: "eye",
                    isEnabledInSystem: systemDifferentiateWithoutColor,
                    isAdditionallyEnabled: $additionallyDifferentiateWithoutColor
                )
                OnboardingAccessibilityToggle(
                    title: "Повышенный контраст",
                    systemImage: "circle.lefthalf.filled",
                    isEnabledInSystem: systemColorSchemeContrast == .increased,
                    isAdditionallyEnabled: $additionallyIncreaseContrast
                )

                Picker("Размер текста", selection: $textSize) {
                    ForEach(AppAccessibilityTextSize.allCases) { option in
                        Text(option.titleKey)
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("onboarding-text-size-picker")

                Text("Third Hand автоматически учитывает параметры macOS. Переключатели выше позволяют дополнительно усилить их только внутри приложения.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    openSystemAccessibilitySettings()
                } label: {
                    Label("Открыть настройки macOS", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("open-macos-accessibility-settings-button")
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.separator.opacity(0.45), lineWidth: 1)
        }
    }

    private func preferenceSection<Content: View>(
        title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 16) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            Spacer(minLength: 20)

            content()
        }
    }

    private func openSystemAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct OnboardingAccessibilityToggle: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isEnabledInSystem: Bool
    @Binding var isAdditionallyEnabled: Bool

    var body: some View {
        Toggle(isOn: effectiveBinding) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text(title)

                if isEnabledInSystem {
                    Text("macOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .disabled(isEnabledInSystem)
    }

    private var effectiveBinding: Binding<Bool> {
        Binding(
            get: { isEnabledInSystem || isAdditionallyEnabled },
            set: { isAdditionallyEnabled = $0 }
        )
    }
}

private struct OnboardingAnimationStep: View {
    @Environment(\.appAccessibilityOptions) private var accessibilityOptions

    var body: some View {
        VStack {
            Spacer(minLength: 44)

            HStack(spacing: 0) {
                ZStack {
                    if accessibilityOptions.reduceMotion,
                       let posterURL = OnboardingVideoResource.posterURL,
                       let poster = NSImage(contentsOf: posterURL) {
                        Image(nsImage: poster)
                            .resizable()
                            .scaledToFit()
                            .padding(28)
                    } else if let videoURL = OnboardingVideoResource.url {
                        OnboardingVideoView(
                            url: videoURL
                        )
                        .padding(28)
                    } else {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .padding(110)
                    }
                }
                .frame(width: 520, height: 520)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Third Hand"))
                .accessibilityIdentifier("onboarding-animation")

                Spacer(minLength: 0)
            }
            .padding(.leading, 64)

            Spacer(minLength: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnboardingFooter: View {
    let currentStep: Int
    let stepCount: Int
    let showsBackButton: Bool
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        HStack {
            if showsBackButton {
                Button("Назад", action: onBack)
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 140, alignment: .leading)
                    .accessibilityIdentifier("onboarding-back-button")
            } else {
                Color.clear
                    .frame(width: 140, height: 1)
            }

            Spacer()

            HStack(spacing: 7) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index == currentStep ? Color.accentColor : Color.secondary.opacity(0.28))
                        .frame(
                            width: index == currentStep ? 24 : 7,
                            height: 7
                        )
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(currentStep + 1) / \(stepCount)"))

            Spacer()

            Button("Продолжить", action: onContinue)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .frame(width: 140, alignment: .trailing)
                .accessibilityIdentifier("onboarding-continue-button")
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
