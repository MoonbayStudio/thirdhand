import SwiftUI

struct InspectorToggleButton: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            store.isShowingInspector.toggle()
        } label: {
            Label(
                store.isShowingInspector
                    ? "Скрыть настройки агента"
                    : "Показать настройки агента",
                systemImage: "sidebar.trailing"
            )
        }
        .help(
            store.isShowingInspector
                ? "Скрыть правую панель"
                : "Показать правую панель"
        )
        .accessibilityIdentifier("toggle-agent-inspector-button")
    }
}

struct DetailCanvasBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.085),
                    Color.purple.opacity(0.035),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

struct ActivityPulse: View {
    let tint: Color
    var compact = false

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.13))

            ProgressView()
                .controlSize(compact ? .mini : .small)
                .tint(tint)
        }
        .frame(width: compact ? 24 : 34, height: compact ? 24 : 34)
    }
}

struct AgentRunElapsedText: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.elapsed(from: startedAt, to: context.date))
                .monospacedDigit()
        }
    }

    private static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

struct AgentRunCapsule: View {
    let run: AgentRunState
    let output: AgentLiveOutput?

    private var activity: AgentActivityPresentation {
        AgentActivityClassifier.presentation(for: run, output: output)
    }

    var body: some View {
        HStack(spacing: 7) {
            ActivityPulse(tint: run.agent.tint, compact: true)

            VStack(alignment: .leading, spacing: 1) {
                Text(activity.current.title)
                    .font(.caption.weight(.semibold))
                AgentRunElapsedText(startedAt: run.startedAt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(run.agent.tint.opacity(0.1), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(run.agent.tint.opacity(0.2), lineWidth: 0.5)
        }
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

struct StatusBadge: View {
    let status: TaskStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(status.tint.opacity(0.11), in: Capsule())
    }
}

struct AgentAvatar: View {
    let kind: AgentKind?
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 0 : 6) {
            Image(systemName: kind?.systemImage ?? "person.crop.circle.badge.questionmark")
                .font(compact ? .title2 : .title)
                .foregroundStyle(kind?.tint ?? .secondary)
                .frame(width: compact ? 38 : 52, height: compact ? 38 : 52)
                .background((kind?.tint ?? .secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: compact ? 10 : 14))

            if !compact {
                Text(kind?.shortName ?? "Без агента")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    func surfaceCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
            }
    }
}

extension TaskStatus {
    var tint: Color {
        switch self {
        case .ready: .secondary
        case .running: .blue
        case .paused: .orange
        case .needsAttention: .red
        case .completed: .green
        }
    }
}

extension AgentKind {
    var tint: Color {
        switch self {
        case .codex: .blue
        case .claudeCode: .orange
        case .antigravity: .purple
        }
    }

    var systemImage: String {
        switch self {
        case .codex: "terminal.fill"
        case .claudeCode: "sparkles"
        case .antigravity: "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
}

extension ValidationOutcome {
    var tint: Color {
        switch self {
        case .passed: .green
        case .failed: .red
        case .running: .blue
        case .cancelled: .orange
        case .notRun: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .running: "progress.indicator"
        case .cancelled: "stop.circle.fill"
        case .notRun: "minus.circle"
        }
    }
}

extension ChangedFile {
    var statusTint: Color {
        if status.contains("?") || status.contains("A") {
            return .green
        }
        if status.contains("D") {
            return .red
        }
        if status.contains("R") {
            return .purple
        }
        return .orange
    }
}

extension Date {
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: .now)
    }
}
