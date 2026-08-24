import SwiftUI

struct SlashCommandPaletteItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let detail: String
    let systemImage: String

    init(command: ChatSlashCommandDescriptor) {
        id = command.id
        title = command.title
        subtitle = command.name
        detail = command.detail
        systemImage = command.systemImage
    }

    init(option: ChatSlashCommandOption) {
        id = option.id
        title = option.title
        subtitle = option.commandText
        detail = option.detail
        systemImage = option.systemImage
    }
}

struct SlashCommandPalette: View {
    let items: [SlashCommandPaletteItem]
    let selectedID: String?
    let onSelect: (String) -> Void
    let onHighlight: (String) -> Void

    private var paletteHeight: CGFloat {
        min(320, CGFloat(items.count) * 46 + 10)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(items) { item in
                    Button {
                        onSelect(item.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .foregroundStyle(.primary)
                                Text(item.subtitle)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 20)

                            Text(item.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .multilineTextAlignment(.trailing)
                        }
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .background {
                            if selectedID == item.id {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.075))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        if isHovering {
                            onHighlight(item.id)
                        }
                    }
                    .accessibilityLabel("\(item.title), \(item.subtitle)")
                    .accessibilityHint(item.detail)
                }
            }
            .padding(5)
        }
        .scrollIndicators(.visible)
        .frame(height: paletteHeight)
        .animation(.spring(response: 0.24, dampingFraction: 0.9), value: paletteHeight)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.72), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}
