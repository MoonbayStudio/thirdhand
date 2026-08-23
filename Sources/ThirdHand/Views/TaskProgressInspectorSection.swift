import SwiftUI

struct TaskProgressInspectorSection: View {
    let task: CodingTask
    let snapshot: GitSnapshot
    let onToggleStep: (UUID) -> Void
    let onOpenDiff: (ChangedFile) -> Void
    let activeValidation: ValidationExecutionState?
    let onRunValidation: (UUID) -> Void
    let onStopValidation: () -> Void
    let onRunAllValidations: () -> Void
    let onDetectValidations: () -> Void
    @AppStorage("showRawTerminalLogs") private var showRawTerminalLogs = false
    @State private var validationLog: ValidationRun?
    @State private var revealedValidationRecipeIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ПРОГРЕСС")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)

            progressSummary
            changedFiles
            steps
            validations
        }
    }

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Этапы")
                    .font(.headline)

                Spacer()

                Text("\(task.completedStepCount) из \(task.steps.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: task.progress)
                .progressViewStyle(.linear)

            HStack(spacing: 10) {
                Label("\(snapshot.changedFiles.count) файлов", systemImage: "doc.on.doc")
                    .foregroundStyle(.secondary)

                if snapshot.additions != nil || snapshot.deletions != nil {
                    Text("+\(snapshot.lineAdditions)")
                        .foregroundStyle(.green)
                    Text("−\(snapshot.lineDeletions)")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption.monospacedDigit())
        }
    }

    @ViewBuilder
    private var changedFiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Изменённые файлы")

                Spacer()

                if let firstFile = snapshot.changedFiles.first {
                    Button("Открыть все…") {
                        onOpenDiff(firstFile)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
            }

            if !snapshot.isGitRepository {
                Label(
                    "Выбранная папка не является Git-репозиторием.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(snapshot.errorMessage ?? "Git snapshot недоступен")
            } else if snapshot.changedFiles.isEmpty {
                Label("Рабочее дерево чистое", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(snapshot.changedFiles.prefix(12))) { file in
                        ChangedFileProgressRow(file: file) {
                            onOpenDiff(file)
                        }
                    }

                    if snapshot.changedFiles.count > 12 {
                        Text("Ещё \(snapshot.changedFiles.count - 12)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("Этапы")

            ForEach(task.steps) { step in
                Button {
                    onToggleStep(step.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(step.isCompleted ? Color.green : Color.secondary)
                            .frame(width: 14)

                        Text(step.title)
                            .foregroundStyle(step.isCompleted ? .secondary : .primary)
                            .strikethrough(step.isCompleted, color: .secondary)
                            .multilineTextAlignment(.leading)

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption)
                .accessibilityLabel(
                    "\(step.isCompleted ? "Завершено" : "Не завершено"): \(step.title)"
                )
            }
        }
    }

    private var validations: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Проверки")

                Spacer()

                if activeValidation != nil {
                    Button("Остановить", action: onStopValidation)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !(task.validationRecipes ?? []).isEmpty {
                    Button("Запустить все", action: onRunAllValidations)
                        .buttonStyle(.plain)
                        .font(.caption)
                } else {
                    Button("Найти", action: onDetectValidations)
                        .buttonStyle(.plain)
                        .font(.caption)
                }
            }

            if (task.validationRecipes ?? []).isEmpty {
                Text("Поддерживаемые команды сборки и тестов не обнаружены.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    "Команды выполняют код репозитория с правами пользователя.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            ForEach(task.validationRecipes ?? []) { recipe in
                let validation = task.validations.first {
                    $0.recipeID == recipe.id || $0.name == recipe.name
                } ?? ValidationRun(name: recipe.name, recipeID: recipe.id)
                let isCurrent = activeValidation?.recipeID == recipe.id

                HStack(alignment: .top, spacing: 8) {
                    if isCurrent {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 14)
                    } else {
                        Image(systemName: validation.outcome.systemImage)
                            .foregroundStyle(validation.outcome.tint)
                            .frame(width: 14)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(recipe.name)
                                .font(.caption.weight(.medium))
                            Spacer()

                            if validation.outcome != .notRun,
                               validation.outcome != .running,
                               !validation.isFresh(for: snapshot) {
                                Text("Устарело")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else {
                                Text(validation.outcome.title)
                                    .font(.caption2)
                                    .foregroundStyle(validation.outcome.tint)
                            }

                            if !isCurrent, activeValidation == nil {
                                Button {
                                    onRunValidation(recipe.id)
                                } label: {
                                    Image(systemName: "play.fill")
                                }
                                .buttonStyle(.plain)
                                .font(.caption2)
                                .help("Запустить \(recipe.commandDescription)")
                            }
                        }

                        Text(recipe.commandDescription)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .textSelection(.enabled)

                        if validation.outcome != .notRun || isCurrent {
                            Text(isCurrent ? "Выполняется…" : validation.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }

                        if !isCurrent, validation.output?.isEmpty == false {
                            if canShowValidationOutput(recipeID: recipe.id) {
                                Button {
                                    validationLog = validation
                                } label: {
                                    Label("Открыть лог", systemImage: "doc.text.magnifyingglass")
                                }
                                .buttonStyle(.plain)
                                .font(.caption2)
                            } else {
                                Button {
                                    revealedValidationRecipeIDs.insert(recipe.id)
                                } label: {
                                    Label("Показать лог", systemImage: "eye")
                                }
                                .buttonStyle(.plain)
                                .font(.caption2)
                                .help("Raw-лог может содержать секреты")
                            }
                        }

                        if isCurrent,
                           let activeValidation,
                           !activeValidation.output.isEmpty {
                            if canShowValidationOutput(recipeID: recipe.id) {
                                Text(
                                    trailingLines(
                                        activeValidation.output,
                                        maximumCount: 4
                                    )
                                )
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            } else {
                                HStack {
                                    Label(
                                        "Live validation log скрыт",
                                        systemImage: "eye.slash"
                                    )
                                    .foregroundStyle(.tertiary)

                                    Spacer()

                                    Button("Показать") {
                                        revealedValidationRecipeIDs.insert(recipe.id)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Raw-лог может содержать секреты")
                                }
                                .font(.caption2)
                            }
                        } else if let duration = validation.duration {
                            Text(
                                duration.formatted(
                                    .number.precision(.fractionLength(1))
                                ) + " с"
                            )
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .sheet(item: $validationLog) { validation in
            ValidationLogView(validation: validation)
        }
        .onChange(of: task.id) {
            validationLog = nil
            revealedValidationRecipeIDs.removeAll()
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func canShowValidationOutput(recipeID: UUID) -> Bool {
        showRawTerminalLogs || revealedValidationRecipeIDs.contains(recipeID)
    }

    private func trailingLines(_ value: String, maximumCount: Int) -> String {
        value.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        .suffix(maximumCount)
        .joined(separator: "\n")
    }
}

private struct ValidationLogView: View {
    let validation: ValidationRun
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(validation.name)
                        .font(.headline)
                    Text(validation.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Готово") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Text(validation.output ?? "Лог недоступен.")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
    }
}

private struct ChangedFileProgressRow: View {
    let file: ChangedFile
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(file.status)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(file.statusTint)
                    .frame(minWidth: 19)

                Text(file.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if file.additions != nil || file.deletions != nil {
                    HStack(spacing: 4) {
                        Text("+\(file.additions ?? 0)")
                            .foregroundStyle(.green)
                        Text("−\(file.deletions ?? 0)")
                            .foregroundStyle(.red)
                    }
                    .font(.caption2.monospacedDigit())
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Открыть diff: \(file.path)")
    }
}
