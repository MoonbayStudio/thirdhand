import SwiftUI

struct TaskSpecificationInspectorSection: View {
    let specification: TaskSpecification
    let canEdit: Bool
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("СПЕЦИФИКАЦИЯ")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("Редактировать…", action: onEdit)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .disabled(!canEdit)
                    .help(
                        canEdit
                            ? "Изменить актуальный контракт задачи"
                            : "Сначала остановите работающего агента"
                    )
            }

            Text(specification.objective.isEmpty ? "Цель ещё не задана." : specification.objective)
                .font(.callout)
                .foregroundStyle(specification.objective.isEmpty ? .secondary : .primary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Label(
                    "\(specification.acceptanceCriteria.count) критериев",
                    systemImage: "checklist"
                )
                Label(
                    "\(specification.constraints.count) ограничений",
                    systemImage: "exclamationmark.shield"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !specification.openQuestions.isEmpty {
                Label(
                    "Открытых вопросов: \(specification.openQuestions.count)",
                    systemImage: "questionmark.bubble"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Text("Ревизия \(specification.revision) · \(specification.updatedAt.relativeDescription)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct TaskSpecificationEditor: View {
    @Environment(\.dismiss) private var dismiss

    let canSave: Bool
    let onSave: (TaskSpecification) -> Void
    @State private var draft: TaskSpecification

    init(
        specification: TaskSpecification,
        canSave: Bool = true,
        onSave: @escaping (TaskSpecification) -> Void
    ) {
        self.canSave = canSave
        self.onSave = onSave
        _draft = State(initialValue: specification)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Актуальная цель") {
                    TextEditor(text: $draft.objective)
                        .font(.body)
                        .frame(minHeight: 92)

                    Text("Это текущий контракт задачи. Исходный запрос при редактировании не меняется.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SpecificationListEditor(
                    title: "Уточнения пользователя",
                    emptyPrompt: "Например: не менять публичный API",
                    values: $draft.requirementUpdates
                )
                SpecificationListEditor(
                    title: "Ограничения",
                    emptyPrompt: "Добавить ограничение",
                    values: $draft.constraints
                )
                SpecificationListEditor(
                    title: "Критерии готовности",
                    emptyPrompt: "Добавить проверяемый критерий",
                    values: $draft.acceptanceCriteria
                )
                SpecificationListEditor(
                    title: "Принятые продуктовые решения",
                    emptyPrompt: "Добавить решение",
                    values: $draft.productDecisions
                )
                SpecificationListEditor(
                    title: "Не входит в задачу",
                    emptyPrompt: "Добавить отменённое требование",
                    values: $draft.outOfScope
                )
                SpecificationListEditor(
                    title: "Открытые вопросы",
                    emptyPrompt: "Добавить вопрос, который нельзя угадывать",
                    values: $draft.openQuestions
                )
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text(
                    canSave
                        ? "Следующая попытка агента получит новую ревизию без истории чата."
                        : "Сохранение недоступно, пока выполняется агент или проверка."
                )
                    .font(.caption)
                    .foregroundStyle(canSave ? Color.secondary : Color.orange)

                Spacer()

                Button("Отмена") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Сохранить") {
                    guard canSave else { return }
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !canSave
                        || draft.objective
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                )
            }
            .padding(16)
        }
        .frame(minWidth: 640, minHeight: 650)
        .navigationTitle("Спецификация задачи")
    }
}

private struct SpecificationListEditor: View {
    let title: String
    let emptyPrompt: String
    @Binding var values: [String]

    var body: some View {
        Section(title) {
            ForEach(values.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField(
                        emptyPrompt,
                        text: Binding(
                            get: { values[index] },
                            set: { values[index] = $0 }
                        ),
                        axis: .vertical
                    )
                    .lineLimit(1...4)

                    Button {
                        values.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Удалить")
                }
            }

            Button {
                values.append("")
            } label: {
                Label("Добавить", systemImage: "plus")
            }
            .disabled(values.count >= 12)
        }
    }
}
