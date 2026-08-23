import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PersonaAvatarView: View {
    let imageData: Data?
    let name: String
    let color: AgentAvatarColor
    var size: CGFloat = 42

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color.tint.opacity(0.34), color.tint.opacity(0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let avatarImage {
                Image(nsImage: avatarImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initial)
                    .font(.system(size: size * 0.40, weight: .semibold, design: .rounded))
                    .foregroundStyle(color.tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(color.tint.opacity(0.30), lineWidth: 0.8)
        }
        .accessibilityLabel(AppLocalization.string("Аватар агента \(displayName)"))
    }

    private var avatarImage: NSImage? {
        imageData.flatMap(NSImage.init(data:))
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppLocalization.string("Агент") : trimmed
    }

    private var initial: String {
        String(displayName.prefix(1)).uppercased()
    }
}

struct PersonaAvatarEditor: View {
    @Binding var imageData: Data?
    @Binding var color: AgentAvatarColor
    let name: String
    let onChoosePhoto: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 13) {
                PersonaAvatarView(
                    imageData: imageData,
                    name: name,
                    color: color,
                    size: 60
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        imageData == nil
                            ? AppLocalization.string("Добавьте фотографию")
                            : AppLocalization.string("Фото загружено")
                    )
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    Text("PNG, JPG или HEIC · до 25 МБ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    choosePhotoButton
                    removePhotoButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    choosePhotoButton
                    removePhotoButton
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Цвет аватара без фото")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    ForEach(AgentAvatarColor.allCases) { option in
                        Button {
                            color = option
                        } label: {
                            Circle()
                                .fill(option.tint)
                                .frame(width: 18, height: 18)
                                .overlay {
                                    if color == option {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppLocalization.string("Цвет \(option.title)"))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var choosePhotoButton: some View {
        Button(action: onChoosePhoto) {
            Label(
                imageData == nil
                    ? AppLocalization.string("Загрузить фото…")
                    : AppLocalization.string("Заменить фото…"),
                systemImage: "photo.badge.plus"
            )
            .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("choose-agent-avatar-button")
    }

    @ViewBuilder
    private var removePhotoButton: some View {
        if imageData != nil {
            Button("Удалить", role: .destructive) {
                imageData = nil
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.red)
        }
    }

}

@MainActor
enum PersonaAvatarImageProcessor {
    private static let maximumSourceBytes = 25 * 1_024 * 1_024
    private static let outputPixels = 512

    static func normalizedImageData(from url: URL) throws -> Data {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maximumSourceBytes {
            throw PersonaAvatarImageError.imageTooLarge
        }

        return try normalizedImageData(from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func normalizedImageData(from sourceData: Data) throws -> Data {
        guard sourceData.count <= maximumSourceBytes else {
            throw PersonaAvatarImageError.imageTooLarge
        }
        guard let image = NSImage(data: sourceData),
              image.size.width > 0,
              image.size.height > 0
        else {
            throw PersonaAvatarImageError.invalidImage
        }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: outputPixels,
            pixelsHigh: outputPixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw PersonaAvatarImageError.processingFailed
        }

        let outputSize = CGFloat(outputPixels)
        let outputRect = NSRect(x: 0, y: 0, width: outputSize, height: outputSize)
        let sourceSide = min(image.size.width, image.size.height)
        let sourceRect = NSRect(
            x: (image.size.width - sourceSide) / 2,
            y: (image.size.height - sourceSide) / 2,
            width: sourceSide,
            height: sourceSide
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        outputRect.fill()
        image.draw(
            in: outputRect,
            from: sourceRect,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let outputData = bitmap.representation(using: .png, properties: [:]) else {
            throw PersonaAvatarImageError.processingFailed
        }
        return outputData
    }
}

private enum PersonaAvatarImageError: LocalizedError {
    case imageTooLarge
    case invalidImage
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .imageTooLarge:
            AppLocalization.string("Файл больше 25 МБ. Выберите изображение поменьше.")
        case .invalidImage:
            AppLocalization.string("Этот файл не удалось распознать как изображение.")
        case .processingFailed:
            AppLocalization.string("Изображение не удалось подготовить для аватара.")
        }
    }
}

extension AgentAvatarColor {
    var tint: Color {
        switch self {
        case .indigo: .indigo
        case .blue: .blue
        case .teal: .teal
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        }
    }

    var title: String {
        switch self {
        case .indigo: AppLocalization.string("Индиго")
        case .blue: AppLocalization.string("Синий")
        case .teal: AppLocalization.string("Бирюзовый")
        case .green: AppLocalization.string("Зелёный")
        case .orange: AppLocalization.string("Оранжевый")
        case .pink: AppLocalization.string("Розовый")
        }
    }
}
