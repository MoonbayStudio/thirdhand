import SwiftUI

struct AgentConfigurationMenu: View {
    @Environment(AppStore.self) private var store
    let task: CodingTask

    private var selectedAgent: AgentKind {
        store.effectiveAgent(for: task)
    }

    private var selectedTarget: AgentExecutionTarget {
        store.preferredExecutionTarget(for: task)
    }

    private var isAutomatic: Bool {
        task.effectiveRoutingMode == .automatic
    }

    private var capabilities: AgentCapabilitySet {
        store.capabilities(for: task)
    }

    private var parameters: [AgentParameterDefinition] {
        if task.effectiveRoutingMode == .manual,
           task.configuredExecutionSource == .api {
            return []
        }
        return store.parameterDefinitions(for: task)
    }

    private var selectedModelID: String? {
        guard let parameter = parameters.first(where: { $0.id == .model }) else { return nil }
        return store.effectiveValue(for: parameter, in: task)
    }

    private var isFast: Bool {
        guard let parameter = parameters.first(where: { $0.id == .speedTier }) else { return false }
        return store.effectiveValue(for: parameter, in: task) == "priority"
    }

    var body: some View {
        Menu {
            agentMenu

            Divider()

            ForEach(parameters) { parameter in
                parameterMenu(parameter)
            }

            Divider()

            Button {
                store.resetAgentConfiguration(for: task.id)
            } label: {
                Label("Сбросить параметры", systemImage: "arrow.counterclockwise")
            }
            .disabled(task.agentConfiguration == nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isFast ? "bolt.fill" : selectedTarget.systemImage)
                    .foregroundStyle(selectedTarget.tint)

                Text(summary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption.weight(.medium))
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .frame(height: 27)
            .frame(maxWidth: 245)
            .background(.quaternary, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help(AppLocalization.string("Агент и параметры запуска"))
        .accessibilityLabel(AppLocalization.string("Параметры агента: \(summary)"))
    }

    private var agentMenu: some View {
        Menu {
            Button {
                store.selectAutomaticRouting(for: task.id)
            } label: {
                if isAutomatic {
                    Label("Авто", systemImage: "checkmark")
                } else {
                    Label("Авто", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Divider()

            ForEach(store.agentInstallations) { installation in
                Button {
                    store.selectAgent(installation.kind, for: task.id)
                } label: {
                    if installation.kind == selectedAgent && !isAutomatic {
                        Label(installation.kind.displayName, systemImage: "checkmark")
                    } else if installation.isAvailable {
                        Text(installation.kind.displayName)
                    } else {
                        Label("\(installation.kind.displayName) — CLI не найден", systemImage: "exclamationmark.circle")
                    }
                }
                .disabled(!installation.isAvailable)
            }

            Divider()

            Menu {
                ForEach(AIAPIProvider.allCases) { provider in
                    let modelID = AIAPIPreferences.primaryModelID(for: provider)
                    Button {
                        store.selectAPI(
                            AIAPITarget(provider: provider, modelID: modelID),
                            for: task.id
                        )
                    } label: {
                        if case let .api(target) = selectedTarget,
                           target.provider == provider,
                           !isAutomatic {
                            Label("\(provider.displayName) · \(modelID)", systemImage: "checkmark")
                        } else {
                            Text(
                                modelID.isEmpty
                                    ? "\(provider.displayName) — модель не выбрана"
                                    : "\(provider.displayName) · \(modelID)"
                            )
                        }
                    }
                    .disabled(modelID.isEmpty)
                }
            } label: {
                Label("API", systemImage: "key.horizontal")
            }
        } label: {
            Label(
                isAutomatic
                    ? "Режим — Авто → \(selectedTarget.shortName)"
                    : "Запуск — \(selectedTarget.shortName)",
                systemImage: isAutomatic
                    ? "arrow.triangle.2.circlepath"
                    : selectedTarget.systemImage
            )
        }
    }

    @ViewBuilder
    private func parameterMenu(_ parameter: AgentParameterDefinition) -> some View {
        let selectedValue = store.effectiveValue(for: parameter, in: task)
        let selectedTitle = parameter.options.first(where: { $0.id == selectedValue })?.title
            ?? selectedValue

        Menu {
            ForEach(parameter.options) { option in
                Button {
                    store.setAgentOption(parameter.id, to: option.id, for: task.id)
                } label: {
                    if option.id == selectedValue {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
                .help(option.detail ?? "")
            }
        } label: {
            Label("\(parameter.title) — \(selectedTitle)", systemImage: parameter.systemImage)
        }
    }

    private var summary: String {
        if case let .api(target) = selectedTarget, !isAutomatic {
            return ["API", target.provider.shortName, target.modelID]
                .joined(separator: " · ")
        }
        let modelTitle = capabilities.model(for: selectedModelID)?.compactTitle
            ?? AppLocalization.string("Модель")

        let secondaryParameter = parameters.first {
            $0.id == .reasoningEffort || $0.id == .executionMode
        }
        let secondaryTitle = secondaryParameter.flatMap { parameter in
            let selectedValue = store.effectiveValue(for: parameter, in: task)
            return parameter.options.first(where: { $0.id == selectedValue })?.title
        }

        return [
            isAutomatic ? AppLocalization.string("Авто") : nil,
            selectedAgent.shortName,
            modelTitle,
            secondaryTitle
        ]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
