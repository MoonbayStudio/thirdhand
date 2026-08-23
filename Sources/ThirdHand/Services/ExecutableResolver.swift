import Foundation

enum ExecutableResolver {
    static func first(named names: [String]) -> String? {
        let fileManager = FileManager.default
        for name in names {
            if name.hasPrefix("/"),
               fileManager.isExecutableFile(atPath: name) {
                return URL(fileURLWithPath: name)
                    .resolvingSymlinksInPath()
                    .path
            }

            for directory in searchDirectories(fileManager: fileManager) {
                let candidate = directory
                    .appendingPathComponent(name)
                    .standardizedFileURL
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate.resolvingSymlinksInPath().path
                }
            }
        }
        return nil
    }

    static func environment(
        forExecutablePath executablePath: String,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        let executableDirectory = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .standardizedFileURL
        var directories = [executableDirectory]
        directories += searchDirectories(fileManager: .default)

        var seen: Set<String> = []
        let path = directories
            .map(\.path)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        environment["PATH"] = path
        return environment
    }

    private static func searchDirectories(
        fileManager: FileManager
    ) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        let environmentDirectories = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) } ?? []
        var directories = environmentDirectories + [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            home.appendingPathComponent(".local/bin", isDirectory: true),
            home.appendingPathComponent(".npm-global/bin", isDirectory: true),
            home.appendingPathComponent(".bun/bin", isDirectory: true),
            home.appendingPathComponent(".volta/bin", isDirectory: true),
            home.appendingPathComponent(".asdf/shims", isDirectory: true),
            home.appendingPathComponent(".pyenv/shims", isDirectory: true)
        ]

        let nvmVersions = home.appendingPathComponent(
            ".nvm/versions/node",
            isDirectory: true
        )
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmVersions,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            directories += versions
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appendingPathComponent("bin", isDirectory: true) }
        }

        var seen: Set<String> = []
        return directories.filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
    }
}
