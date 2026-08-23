import SwiftUI

struct AutomaticRoutingSettingsView: View {
    @State private var automaticAgentOrder = AgentRoutingPreferences.load()

    var body: some View {
        Form {
            Section("Порядок провайдеров") {
                ForEach(Array(automaticAgentOrder.enumerated()), id: \.element) { index, agent in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        Label(agent.displayName, systemImage: agent.systemImage)
                            .foregroundStyle(agent.tint)

                        Spacer()

                        Button {
                            moveAgent(at: index, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.plain)
                        .disabled(index == automaticAgentOrder.startIndex)
                        .help("Поднять в очереди")

                        Button {
                            moveAgent(at: index, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .disabled(index == automaticAgentOrder.index(before: automaticAgentOrder.endIndex))
                        .help("Опустить в очереди")
                    }
                    .padding(.vertical, 3)
                }

                Text("В режиме Авто Third Hand идёт сверху вниз и переключается только после подтверждённой ошибки лимита. Ошибки сети, авторизации и разрешений не запускают другого агента автоматически.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func moveAgent(at index: Int, by offset: Int) {
        let destination = index + offset
        guard automaticAgentOrder.indices.contains(index),
              automaticAgentOrder.indices.contains(destination)
        else {
            return
        }

        automaticAgentOrder.swapAt(index, destination)
        AgentRoutingPreferences.save(automaticAgentOrder)
    }
}
