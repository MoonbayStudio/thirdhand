import SwiftUI

struct SettingsView: View {
    let section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.system(size: 26, weight: .semibold))
                .padding(.horizontal, 76)
                .padding(.top, 48)
                .padding(.bottom, 8)

            Group {
                switch section {
                case .general:
                    GeneralSettingsView()
                case .privacy:
                    PrivacySettingsView()
                case .automaticRouting:
                    AutomaticRoutingSettingsView()
                case .handoff:
                    OpenRouterSettingsView()
                }
            }
            .frame(maxWidth: 860, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            DetailCanvasBackground()
        }
    }
}
