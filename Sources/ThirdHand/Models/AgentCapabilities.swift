import Foundation

struct AgentValueOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var detail: String?

    init(_ id: String, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

struct AgentModelCapability: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let compactTitle: String
    var detail: String?
    var reasoningEfforts: [AgentValueOption]
    var defaultReasoningEffort: String?
    var supportsFastTier: Bool

    init(
        id: String,
        title: String,
        compactTitle: String? = nil,
        detail: String? = nil,
        reasoningEfforts: [AgentValueOption] = [],
        defaultReasoningEffort: String? = nil,
        supportsFastTier: Bool = false
    ) {
        self.id = id
        self.title = title
        self.compactTitle = compactTitle ?? title
        self.detail = detail
        self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportsFastTier = supportsFastTier
    }
}

struct AgentParameterDefinition: Identifiable, Hashable, Sendable {
    let id: AgentOptionID
    let title: String
    let systemImage: String
    let options: [AgentValueOption]
    let defaultValue: String
}

struct AgentCapabilitySet: Identifiable, Hashable, Sendable {
    var id: AgentKind { kind }
    let kind: AgentKind
    var models: [AgentModelCapability]

    var defaultModelID: String {
        models.first?.id ?? "default"
    }

    func model(for id: String?) -> AgentModelCapability? {
        guard let id, let model = models.first(where: { $0.id == id }) else {
            return models.first
        }
        return model
    }

    func parameters(selectedModelID: String?) -> [AgentParameterDefinition] {
        let selectedModel = model(for: selectedModelID)
        var definitions = [
            AgentParameterDefinition(
                id: .model,
                title: "Модель",
                systemImage: "cpu",
                options: models.map { AgentValueOption($0.id, title: $0.title, detail: $0.detail) },
                defaultValue: defaultModelID
            )
        ]

        switch kind {
        case .codex:
            if let selectedModel, !selectedModel.reasoningEfforts.isEmpty {
                definitions.append(
                    AgentParameterDefinition(
                        id: .reasoningEffort,
                        title: "Усилие",
                        systemImage: "brain.head.profile",
                        options: selectedModel.reasoningEfforts,
                        defaultValue: selectedModel.defaultReasoningEffort
                            ?? selectedModel.reasoningEfforts.first?.id
                            ?? "medium"
                    )
                )
            }

            if selectedModel?.supportsFastTier == true {
                definitions.append(
                    AgentParameterDefinition(
                        id: .speedTier,
                        title: "Скорость",
                        systemImage: "bolt.fill",
                        options: [
                            AgentValueOption("standard", title: "Стандартная"),
                            AgentValueOption("priority", title: "Быстрая", detail: "Примерно 1,5×; расходует больше лимита")
                        ],
                        defaultValue: "standard"
                    )
                )
            }

            definitions.append(contentsOf: [
                AgentParameterDefinition(
                    id: .sandboxMode,
                    title: "Доступ к файлам",
                    systemImage: "folder.badge.gearshape",
                    options: [
                        AgentValueOption("read-only", title: "Только чтение"),
                        AgentValueOption("workspace-write", title: "Текущий репозиторий"),
                        AgentValueOption("danger-full-access", title: "Полный доступ")
                    ],
                    defaultValue: "workspace-write"
                ),
                AgentParameterDefinition(
                    id: .approvalPolicy,
                    title: "Подтверждения",
                    systemImage: "hand.raised",
                    options: [
                        AgentValueOption("untrusted", title: "Для непроверенных команд"),
                        AgentValueOption("on-request", title: "По запросу агента"),
                        AgentValueOption("never", title: "Не спрашивать")
                    ],
                    defaultValue: "on-request"
                )
            ])

        case .claudeCode:
            definitions.append(contentsOf: [
                AgentParameterDefinition(
                    id: .reasoningEffort,
                    title: "Усилие",
                    systemImage: "brain.head.profile",
                    options: Self.reasoningOptions.filter { $0.id != "ultra" },
                    defaultValue: "high"
                ),
                AgentParameterDefinition(
                    id: .permissionMode,
                    title: "Разрешения",
                    systemImage: "hand.raised",
                    options: [
                        AgentValueOption("manual", title: "Вручную"),
                        AgentValueOption("auto", title: "Автоматически"),
                        AgentValueOption("acceptEdits", title: "Принимать правки"),
                        AgentValueOption("dontAsk", title: "Не спрашивать"),
                        AgentValueOption("plan", title: "Только план")
                    ],
                    defaultValue: "manual"
                )
            ])

        case .antigravity:
            definitions.append(contentsOf: [
                AgentParameterDefinition(
                    id: .executionMode,
                    title: "Режим",
                    systemImage: "slider.horizontal.3",
                    options: [
                        AgentValueOption("accept-edits", title: "Принимать правки"),
                        AgentValueOption("plan", title: "Только план")
                    ],
                    defaultValue: "accept-edits"
                ),
                AgentParameterDefinition(
                    id: .sandboxMode,
                    title: "Песочница",
                    systemImage: "shippingbox",
                    options: [
                        AgentValueOption("disabled", title: "Выключена"),
                        AgentValueOption("enabled", title: "Включена")
                    ],
                    defaultValue: "disabled"
                )
            ])
        }

        return definitions.filter { !$0.options.isEmpty }
    }

    static let reasoningOptions = [
        AgentValueOption("low", title: "Низкое"),
        AgentValueOption("medium", title: "Среднее"),
        AgentValueOption("high", title: "Высокое"),
        AgentValueOption("xhigh", title: "Очень высокое"),
        AgentValueOption("max", title: "Максимальное"),
        AgentValueOption("ultra", title: "Ультра", detail: "Максимум рассуждений и автоматическая делегация")
    ]
}

enum AgentCapabilityCatalog {
    static let fallback: [AgentKind: AgentCapabilitySet] = [
        .codex: AgentCapabilitySet(
            kind: .codex,
            models: [
                codexModel("gpt-5.6-sol", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "low", fast: true),
                codexModel("gpt-5.6-terra", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "medium", fast: true),
                codexModel("gpt-5.6-luna", efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "medium", fast: true),
                codexModel("gpt-5.5", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium", fast: true),
                codexModel("gpt-5.4", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium", fast: true),
                codexModel("gpt-5.4-mini", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium", fast: false),
                codexModel("gpt-5.2", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium", fast: false)
            ]
        ),
        .claudeCode: AgentCapabilitySet(
            kind: .claudeCode,
            models: [
                AgentModelCapability(id: "default", title: "По умолчанию"),
                AgentModelCapability(id: "sonnet", title: "Claude Sonnet"),
                AgentModelCapability(id: "opus", title: "Claude Opus"),
                AgentModelCapability(id: "fable", title: "Claude Fable")
            ]
        ),
        .antigravity: AgentCapabilitySet(
            kind: .antigravity,
            models: [
                "Gemini 3.6 Flash (High)",
                "Gemini 3.6 Flash (Medium)",
                "Gemini 3.6 Flash (Low)",
                "Gemini 3.5 Flash (High)",
                "Gemini 3.5 Flash (Medium)",
                "Gemini 3.5 Flash (Low)",
                "Gemini 3.1 Pro (High)",
                "Gemini 3.1 Pro (Low)",
                "Claude Sonnet 4.6 (Thinking)",
                "Claude Opus 4.6 (Thinking)",
                "GPT-OSS 120B (Medium)"
            ].map { AgentModelCapability(id: $0, title: $0) }
        )
    ]

    static func codexModel(
        _ id: String,
        title: String? = nil,
        detail: String? = nil,
        efforts: [String],
        defaultEffort: String,
        fast: Bool
    ) -> AgentModelCapability {
        AgentModelCapability(
            id: id,
            title: title ?? codexModelTitle(id),
            compactTitle: codexModelTitle(id),
            detail: detail,
            reasoningEfforts: efforts.compactMap { effort in
                AgentCapabilitySet.reasoningOptions.first { $0.id == effort }
            },
            defaultReasoningEffort: defaultEffort,
            supportsFastTier: fast
        )
    }

    static func codexModelTitle(_ id: String) -> String {
        id
            .replacingOccurrences(of: "gpt-", with: "", options: [.caseInsensitive, .anchored])
            .split(separator: "-")
            .map { part in
                part.first.map { String($0).uppercased() + part.dropFirst() } ?? ""
            }
            .joined(separator: " ")
    }
}
