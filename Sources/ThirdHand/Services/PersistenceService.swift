import Foundation

struct PersistenceLoadState {
    let tasks: [CodingTask]
    let warning: String?
    let allowsWrites: Bool
}

struct GroupChatPersistenceLoadState {
    let groupChats: [AgentGroupChat]
    let warning: String?
    let allowsWrites: Bool
}

struct PersistenceService {
    private let stateURL: URL

    private var backupURL: URL {
        stateURL.appendingPathExtension("backup")
    }

    private var groupChatsURL: URL {
        stateURL
            .deletingLastPathComponent()
            .appendingPathComponent("group-chats.json")
    }

    private var groupChatsBackupURL: URL {
        groupChatsURL.appendingPathExtension("backup")
    }

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Third Hand", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        stateURL = directory.appendingPathComponent("state.json")
    }

    init(stateURL: URL) {
        self.stateURL = stateURL
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func loadTasks() -> PersistenceLoadState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return PersistenceLoadState(tasks: [], warning: nil, allowsWrites: true)
        }

        do {
            let data = try Data(contentsOf: stateURL)
            let tasks = try JSONDecoder.thirdHand.decode([CodingTask].self, from: data)
            return PersistenceLoadState(tasks: tasks, warning: nil, allowsWrites: true)
        } catch {
            if let backupData = try? Data(contentsOf: backupURL),
               let backupTasks = try? JSONDecoder.thirdHand.decode(
                   [CodingTask].self,
                   from: backupData
               ) {
                let corruptArchiveURL = stateURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        "\(stateURL.lastPathComponent).corrupt-\(UUID().uuidString)"
                    )
                do {
                    try FileManager.default.copyItem(
                        at: stateURL,
                        to: corruptArchiveURL
                    )
                    try backupData.write(to: stateURL, options: .atomic)
                } catch {
                    return PersistenceLoadState(
                        tasks: backupTasks,
                        warning: "Файл состояния повреждён. Резервная копия доступна только для чтения: не удалось безопасно сохранить повреждённый файл (\(error.localizedDescription)).",
                        allowsWrites: false
                    )
                }
                return PersistenceLoadState(
                    tasks: backupTasks,
                    warning: "Файл состояния повреждён. Third Hand сохранил исходник как \(corruptArchiveURL.lastPathComponent) и восстановил рабочее состояние из резервной копии.",
                    allowsWrites: true
                )
            }

            return PersistenceLoadState(
                tasks: [],
                warning: "Не удалось прочитать \(stateURL.path). Third Hand не будет перезаписывать повреждённый файл.",
                allowsWrites: false
            )
        }
    }

    func saveTasks(_ tasks: [CodingTask]) throws {
        if let existingData = try? Data(contentsOf: stateURL),
           (try? JSONDecoder.thirdHand.decode(
               [CodingTask].self,
               from: existingData
           )) != nil {
            try existingData.write(to: backupURL, options: .atomic)
        }

        let data = try JSONEncoder.thirdHand.encode(tasks)
        try data.write(to: stateURL, options: .atomic)
    }

    func loadGroupChats() -> GroupChatPersistenceLoadState {
        guard FileManager.default.fileExists(atPath: groupChatsURL.path) else {
            return GroupChatPersistenceLoadState(
                groupChats: [],
                warning: nil,
                allowsWrites: true
            )
        }

        do {
            let data = try Data(contentsOf: groupChatsURL)
            let groupChats = try JSONDecoder.thirdHand.decode(
                [AgentGroupChat].self,
                from: data
            )
            return GroupChatPersistenceLoadState(
                groupChats: groupChats,
                warning: nil,
                allowsWrites: true
            )
        } catch {
            if let backupData = try? Data(contentsOf: groupChatsBackupURL),
               let backupChats = try? JSONDecoder.thirdHand.decode(
                   [AgentGroupChat].self,
                   from: backupData
               ) {
                let corruptArchiveURL = groupChatsURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        "\(groupChatsURL.lastPathComponent).corrupt-\(UUID().uuidString)"
                    )
                do {
                    try FileManager.default.copyItem(
                        at: groupChatsURL,
                        to: corruptArchiveURL
                    )
                    try backupData.write(to: groupChatsURL, options: .atomic)
                } catch {
                    return GroupChatPersistenceLoadState(
                        groupChats: backupChats,
                        warning: "Файл групповых чатов повреждён. Резервная копия доступна только для чтения: \(error.localizedDescription)",
                        allowsWrites: false
                    )
                }
                return GroupChatPersistenceLoadState(
                    groupChats: backupChats,
                    warning: "Файл групповых чатов восстановлен из резервной копии. Повреждённый исходник сохранён как \(corruptArchiveURL.lastPathComponent).",
                    allowsWrites: true
                )
            }

            return GroupChatPersistenceLoadState(
                groupChats: [],
                warning: "Не удалось прочитать \(groupChatsURL.path). Third Hand не будет перезаписывать повреждённый файл.",
                allowsWrites: false
            )
        }
    }

    func saveGroupChats(_ groupChats: [AgentGroupChat]) throws {
        if let existingData = try? Data(contentsOf: groupChatsURL),
           (try? JSONDecoder.thirdHand.decode(
               [AgentGroupChat].self,
               from: existingData
           )) != nil {
            try existingData.write(to: groupChatsBackupURL, options: .atomic)
        }

        let data = try JSONEncoder.thirdHand.encode(groupChats)
        try data.write(to: groupChatsURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var thirdHand: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var thirdHand: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
