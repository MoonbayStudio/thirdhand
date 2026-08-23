import SwiftUI

struct NewGroupChatSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var selectedParticipantIDs: Set<UUID> = []
    @State private var validationMessage: String?

    private var agents: [CodingTask] {
        store.groupChatEligibleAgents
    }

    private var canCreate: Bool {
        (2...8).contains(selectedParticipantIDs.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Новый групповой чат", systemImage: "person.3.fill")
                .font(.title2.weight(.semibold))

            Text("Выберите агентов. В чате к ним можно обращаться прямо по имени — символ @ не нужен.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
    }

    @ViewBuilder
    private var content: some View {
        if agents.count < 2 {
            ContentUnavailableView {
                Label("Нужно минимум два агента", systemImage: "person.2.badge.plus")
            } description: {
                Text("Сначала создайте ещё одного агента, затем соберите их в групповой чат.")
            } actions: {
                Button("Создать агента") {
                    dismiss()
                    store.beginAgentCreation()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Название")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    TextField("Например, Идея приложения", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("group-chat-title-field")
                }

                HStack {
                    Text("Участники")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Text("\(selectedParticipantIDs.count) из 8")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(agents) { agent in
                            participantRow(agent)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Названия агентов должны отличаться — по ним Third Hand понимает, кого вы позвали в обсуждение.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
        }
    }

    private func participantRow(_ agent: CodingTask) -> some View {
        let isSelected = selectedParticipantIDs.contains(agent.id)
        return Button {
            toggle(agent)
        } label: {
            HStack(spacing: 12) {
                PersonaAvatarView(
                    imageData: agent.effectivePersona.avatarImageData,
                    name: agent.title,
                    color: agent.effectivePersona.avatarColor,
                    size: 42
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(GroupChatPromptBuilder.shortRole(for: agent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(11)
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.28) : Color.clear,
                        lineWidth: 0.7
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("group-participant-\(agent.id.uuidString)")
    }

    private var footer: some View {
        HStack {
            Button("Отмена") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Создать чат") {
                createGroup()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
            .accessibilityIdentifier("create-group-chat-button")
        }
        .padding(18)
    }

    private func toggle(_ agent: CodingTask) {
        validationMessage = nil
        if selectedParticipantIDs.contains(agent.id) {
            selectedParticipantIDs.remove(agent.id)
        } else if selectedParticipantIDs.count < 8 {
            selectedParticipantIDs.insert(agent.id)
        } else {
            validationMessage = "Можно выбрать не больше восьми агентов."
        }
    }

    private func createGroup() {
        let orderedIDs = agents
            .map(\.id)
            .filter(selectedParticipantIDs.contains)
        guard store.createGroupChat(
            title: title,
            participantIDs: orderedIDs
        ) != nil else {
            validationMessage = store.lastError
            return
        }
        dismiss()
    }
}
