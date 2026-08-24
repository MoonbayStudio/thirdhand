import SwiftUI

struct AppLaunchView: View {
    @AppStorage(AppPreferenceKeys.completedOnboardingVersion)
    private var completedOnboardingVersion = 0

    var body: some View {
        Group {
            if completedOnboardingVersion >= OnboardingFlow.currentVersion {
                RootView()
            } else {
                OnboardingView {
                    completedOnboardingVersion = OnboardingFlow.currentVersion
                }
            }
        }
    }
}

enum OnboardingFlow {
    static let currentVersion = 1
}
