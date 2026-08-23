import SwiftUI

struct InspectorView: View {
    @Environment(AppStore.self) private var store
    let task: CodingTask?
    @State private var isEditingSpecification = false
    @State private var diffFile: ChangedFile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let task {
                    currentAttempt(task)
                    TaskSpecificationInspectorSection(
                        specification: task.effectiveSpecification,
                        canEdit: !store.isRepositoryBusyForInteraction(
                            task.repositoryPath
                        ),
                        onEdit: {
                            isEditingSpecification = true
                        }
                    )
                    Divider()
                    TaskProgressInspectorSection(
                        task: task,
                        snapshot: store.displayedGitSnapshot(for: task),
                        onToggleStep: { stepID in
                            store.toggleStep(taskID: task.id, stepID: stepID)
                        },
                        onOpenDiff: { file in
                            diffFile = file
                        },
                        activeValidation: store.activeValidations[task.id],
                        onRunValidation: { recipeID in
                            Task {
                                await store.runValidation(
                                    taskID: task.id,
                                    recipeID: recipeID
                                )
                            }
                        },
                        onStopValidation: {
                            Task {
                                await store.stopValidation(taskID: task.id)
                            }
                        },
                        onRunAllValidations: {
                            Task {
                                await store.runAllValidations(taskID: task.id)
                            }
                        },
                        onDetectValidations: {
                            Task {
                                await store.detectValidationRecipes(
                                    taskID: task.id,
                                    force: true
                                )
                            }
                        }
                    )
                    Divider()
                    repository(task, snapshot: store.displayedGitSnapshot(for: task))
                    Divider()
                }

                agents

                if task != nil {
                    Divider()
                    architectureNotice
                }
            }
            .padding(16)
        }
        .background(.ultraThinMaterial)
        .sheet(isPresented: $isEditingSpecification) {
            if let task {
                TaskSpecificationEditor(
                    specification: task.effectiveSpecification,
                    canSave: !store.isRepositoryBusyForInteraction(
                        task.repositoryPath
                    ),
                    onSave: { specification in
                        store.updateSpecification(specification, for: task.id)
                    }
                )
            }
        }
        .sheet(item: $diffFile) { file in
            if let task {
                TaskChangesView(
                    taskTitle: task.title,
                    repositoryPath: task.repositoryPath,
                    files: store.displayedGitSnapshot(for: task).changedFiles,
                    initiallySelectedFile: file
                )
            }
        }
        .task(id: task?.id) {
            guard let task else { return }
            await store.detectValidationRecipes(taskID: task.id)
        }
    }

    private func currentAttempt(_ task: CodingTask) -> some View {
        let run = store.activeRuns[task.id]
        let activity = run.map {
            AgentActivityClassifier.presentation(
                for: $0,
                output: store.liveAgentOutputs[task.id]
            )
        }

        return VStack(alignment: .leading, spacing: 12) {
            InspectorSectionTitle(run == nil ? "Текущий агент" : "Сейчас выполняется")

            HStack(spacing: 12) {
                AgentAvatar(kind: run?.agent ?? task.currentAgent, compact: true)

                VStack(alignment: .leading, spacing: 2) {
                    Text((run?.agent ?? task.currentAgent)?.displayName ?? "Агент не назначен")
                        .font(.headline)
                    Text(run == nil ? task.status.title : "Активная CLI-попытка")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let run {
                    ActivityPulse(tint: run.agent.tint, compact: true)
                }
            }

            if let run, let activity {
                Divider()

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: activity.current.systemImage)
                        .foregroundStyle(run.agent.tint)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.current.title)
                            .font(.callout.weight(.semibold))
                        Text(activity.current.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 6)

                    AgentRunElapsedText(startedAt: run.startedAt)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            LabeledContent(
                "Маршрутизация",
                value: task.effectiveRoutingMode == .automatic
                    ? "Авто → \(store.effectiveAgent(for: task).shortName)"
                    : "Вручную"
            )
            LabeledContent("Checkpoints", value: "\(task.checkpoints.count)")
            LabeledContent(
                "Этап",
                value: "\(min(task.completedStepCount + 1, task.steps.count)) / \(task.steps.count)"
            )
        }
        .surfaceCard(padding: 14)
    }

    private func repository(_ task: CodingTask, snapshot: GitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorSectionTitle("Worktree")

            LabeledContent("Ветка", value: snapshot.branch)
            LabeledContent("HEAD", value: snapshot.head)
            LabeledContent("Изменения", value: "\(snapshot.changedFiles.count)")

            Text(task.repositoryPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSectionTitle("Агенты")

            ForEach(store.agentInstallations) { installation in
                HStack(spacing: 10) {
                    Image(systemName: installation.isAvailable ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(installation.isAvailable ? Color.green : Color.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(installation.kind.displayName)
                        Text(installation.executablePath ?? "CLI не найден")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var architectureNotice: some View {
        VStack(alignment: .leading, spacing: 9) {
            InspectorSectionTitle("Как это работает")

            Label("Отдельный запуск для каждого сообщения", systemImage: "terminal")
                .font(.headline)

            Text("Контекст собирается из задачи, Git и handoff. История чата не передаётся CLI целиком.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .surfaceCard(padding: 13)
    }
}

private struct InspectorSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}
