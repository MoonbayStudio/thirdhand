import SwiftUI

struct ProviderUsageSummaryView: View {
    let agent: AgentKind
    let routingMode: AgentRoutingMode
    let snapshot: ProviderUsageSnapshot
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            usageRings

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text(snapshot.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if snapshot.source == .officialCLI,
                   snapshot.state != .unknown {
                    HStack(spacing: 3) {
                        Text("Обновлено")
                        Text(snapshot.updatedAt, style: .relative)
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 2)

            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                        .frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .foregroundStyle(.secondary)
            .help("Обновить сейчас. Автообновление работает каждые 5 минут, пока приложение активно.")
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        routingMode == .automatic
            ? "Авто · \(agent.shortName)"
            : agent.shortName
    }

    @ViewBuilder
    private var usageRings: some View {
        if snapshot.windows.isEmpty || snapshot.state == .unknown {
            UnknownUsageRing(tint: agent.tint)
        } else {
            HStack(spacing: 6) {
                ForEach(Array(snapshot.windows.prefix(2))) { window in
                    ProviderUsageRing(
                        window: window,
                        tint: snapshot.state == .exhausted ? .red : agent.tint
                    )
                }
            }
        }
    }

}

private struct ProviderUsageRing: View {
    let window: ProviderUsageWindow
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 3)

                Circle()
                    .trim(from: 0, to: window.remainingFraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Text("\(window.remainingPercent)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 32, height: 32)

            Text(window.title)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 42)
        }
        .help(helpText)
    }

    private var helpText: String {
        var value = "\(window.title): осталось \(window.remainingPercent)%"
        if let resetsAt = window.resetsAt {
            value += ", обновится \(resetsAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return value
    }
}

private struct UnknownUsageRing: View {
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(
                        tint.opacity(0.45),
                        style: StrokeStyle(lineWidth: 2.5, dash: [2.5, 3])
                    )

                Text("—")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 32, height: 32)

            Text("Лимит")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .help("Официальный CLI не сообщает остаток лимита")
    }
}
