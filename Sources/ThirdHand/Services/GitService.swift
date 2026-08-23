import CryptoKit
import Foundation

struct GitService: Sendable {
    private static let emptyTreeHash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    func snapshot(at repositoryURL: URL) async -> GitSnapshot {
        await Task.detached(priority: .userInitiated) {
            Self.captureSnapshot(at: repositoryURL)
        }.value
    }

    func handoffContext(at repositoryURL: URL) async -> RepositoryHandoffContext {
        await Task.detached(priority: .userInitiated) {
            Self.captureHandoffContext(at: repositoryURL)
        }.value
    }

    func fileDiff(
        at repositoryURL: URL,
        file: ChangedFile
    ) async -> GitFileDiff {
        await Task.detached(priority: .userInitiated) {
            Self.captureFileDiff(at: repositoryURL, file: file)
        }.value
    }

    private static func captureSnapshot(at repositoryURL: URL) -> GitSnapshot {
        let rootCheck = runGit(["rev-parse", "--show-toplevel"], at: repositoryURL)
        guard rootCheck.exitCode == 0 else {
            return GitSnapshot(
                branch: "Не Git-репозиторий",
                head: "—",
                changedFiles: [],
                diffStat: "Выбранная папка не содержит Git-репозиторий.",
                capturedAt: .now,
                isGitRepository: false,
                errorMessage: rootCheck.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let branchResult = runGit(["branch", "--show-current"], at: repositoryURL)
        let headResult = runGit(["rev-parse", "--short", "HEAD"], at: repositoryURL)
        let statusResult = runGit(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            at: repositoryURL
        )
        let hasHead = runGit(["rev-parse", "--verify", "HEAD"], at: repositoryURL).exitCode == 0
        let baseTreeish = hasHead ? "HEAD" : emptyTreeHash
        let diffStatResult = runGit(
            ["diff", "--stat", baseTreeish],
            at: repositoryURL
        )
        let numStatResult = runGit(
            ["diff", "--numstat", baseTreeish],
            at: repositoryURL
        )

        let branch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = headResult.exitCode == 0
            ? headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : "нет коммитов"

        let lineStats = parseNumStat(numStatResult.stdout)
        let changedFiles = parsePorcelain(statusResult.stdout).map { file in
            guard let stats = lineStats.byPath[file.path] else { return file }
            return ChangedFile(
                status: file.status,
                path: file.path,
                additions: stats.additions,
                deletions: stats.deletions
            )
        }

        return GitSnapshot(
            branch: branch.isEmpty ? "detached HEAD" : branch,
            head: head,
            changedFiles: changedFiles,
            diffStat: normalizedDiffStat(diffStatResult.stdout),
            capturedAt: .now,
            isGitRepository: true,
            errorMessage: statusResult.exitCode == 0 ? nil : statusResult.stderr,
            additions: lineStats.additions,
            deletions: lineStats.deletions,
            fingerprint: repositoryFingerprint(
                at: repositoryURL,
                hasHead: hasHead,
                statusOutput: statusResult.stdout,
                changedFiles: changedFiles
            )
        )
    }

    private static func captureFileDiff(
        at repositoryURL: URL,
        file: ChangedFile
    ) -> GitFileDiff {
        let rootCheck = runGit(["rev-parse", "--show-toplevel"], at: repositoryURL)
        guard rootCheck.exitCode == 0 else {
            return GitFileDiff(
                path: file.path,
                content: "Git diff недоступен: папка больше не является репозиторием.",
                kind: .unavailable,
                wasTruncated: false
            )
        }

        let repositoryRoot = URL(
            fileURLWithPath: rootCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            isDirectory: true
        ).standardizedFileURL
        guard let fileURL = safeFileURL(path: file.path, repositoryRoot: repositoryRoot) else {
            return GitFileDiff(
                path: file.path,
                content: "Third Hand заблокировал путь за пределами репозитория.",
                kind: .unavailable,
                wasTruncated: false
            )
        }

        if file.status.contains("?") {
            return synthesizedUntrackedDiff(fileURL: fileURL, relativePath: file.path)
        }

        let hasHead = runGit(
            ["rev-parse", "--verify", "HEAD"],
            at: repositoryRoot
        ).exitCode == 0
        let arguments = [
            "diff", "--no-color", "--no-ext-diff", "--no-textconv",
            hasHead ? "HEAD" : emptyTreeHash, "--", file.path
        ]
        let limitedResult = runGitLimited(
            arguments,
            at: repositoryRoot,
            maximumOutputBytes: 1_000_000
        )
        let result = limitedResult.result
        guard result.exitCode == 0 else {
            return GitFileDiff(
                path: file.path,
                content: result.stderr.isEmpty
                    ? "Не удалось получить изменения файла."
                    : result.stderr,
                kind: .unavailable,
                wasTruncated: false
            )
        }

        let content = result.stdout.isEmpty
            ? "Для этого файла нет текстового diff относительно HEAD."
            : result.stdout
        var limitedContent = limitedDiff(content)
        if limitedResult.wasTruncated, !limitedContent.wasTruncated {
            limitedContent = (
                limitedContent.value + "\n\n[Diff truncated by Third Hand.]",
                true
            )
        }
        let isBinary = content.localizedCaseInsensitiveContains("Binary files")
            || content.localizedCaseInsensitiveContains("GIT binary patch")
        return GitFileDiff(
            path: file.path,
            content: limitedContent.value,
            kind: isBinary ? .binary : .text,
            wasTruncated: limitedContent.wasTruncated
        )
    }

    private static func captureHandoffContext(at repositoryURL: URL) -> RepositoryHandoffContext {
        let rootCheck = runGit(["rev-parse", "--show-toplevel"], at: repositoryURL)
        guard rootCheck.exitCode == 0 else {
            return RepositoryHandoffContext(
                status: "Выбранная папка не является Git-репозиторием.",
                diff: "Git diff недоступен.",
                diffStat: "Git diff stat недоступен.",
                isGitRepository: false
            )
        }

        let statusResult = runGit(
            ["status", "--short", "--branch", "--untracked-files=all"],
            at: repositoryURL
        )
        let hasHead = runGit(["rev-parse", "--verify", "HEAD"], at: repositoryURL).exitCode == 0
        let baseTreeish = hasHead ? "HEAD" : emptyTreeHash
        let diffResult = runGitLimited(
            ["diff", "--no-ext-diff", "--no-textconv", baseTreeish],
            at: repositoryURL,
            maximumOutputBytes: 120_000
        )
        let diffStatResult = runGitLimited(
            ["diff", "--stat", baseTreeish],
            at: repositoryURL,
            maximumOutputBytes: 256_000
        )
        let diffOutput = normalized(
            diffResult.result.stdout,
            empty: "Нет изменений в отслеживаемых файлах."
        ) + (diffResult.wasTruncated
            ? "\n\n[Diff truncated by Third Hand after 120000 bytes.]"
            : "")

        return RepositoryHandoffContext(
            status: normalized(statusResult.stdout, empty: "Рабочее дерево чистое."),
            diff: diffOutput,
            diffStat: normalized(
                diffStatResult.result.stdout,
                empty: "Нет изменений в отслеживаемых файлах."
            ) + (diffStatResult.wasTruncated
                ? "\n[Diff stat truncated by Third Hand.]"
                : ""),
            isGitRepository: true
        )
    }

    private static func normalizedDiffStat(_ output: String) -> String {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Нет изменений в отслеживаемых файлах" : value
    }

    private static func normalized(_ output: String, empty fallback: String) -> String {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }

    private static func limitedWithFlag(
        _ output: String,
        maximumCharacters: Int
    ) -> (value: String, wasTruncated: Bool) {
        guard output.count > maximumCharacters else {
            return (output, false)
        }
        return (
            String(output.prefix(maximumCharacters))
                + "\n\n[Diff truncated by Third Hand.]",
            true
        )
    }

    private static func limitedDiff(
        _ output: String
    ) -> (value: String, wasTruncated: Bool) {
        let characterLimited = limitedWithFlag(
            output,
            maximumCharacters: 1_000_000
        )
        let lines = characterLimited.value.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard lines.count > 20_000 else { return characterLimited }
        return (
            lines.prefix(20_000).joined(separator: "\n")
                + "\n[Diff truncated by Third Hand.]",
            true
        )
    }

    private static func safeFileURL(
        path: String,
        repositoryRoot: URL
    ) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let resolvedRoot = repositoryRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate = resolvedRoot
            .appendingPathComponent(path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }

    private static func synthesizedUntrackedDiff(
        fileURL: URL,
        relativePath: String
    ) -> GitFileDiff {
        guard let values = try? fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey
        ]),
        values.isRegularFile == true
        else {
            return GitFileDiff(
                path: relativePath,
                content: "Новый объект нельзя показать как обычный файл.",
                kind: .unavailable,
                wasTruncated: false
            )
        }

        let maximumBytes = 1_000_000
        guard let fileSize = values.fileSize, fileSize <= maximumBytes else {
            return GitFileDiff(
                path: relativePath,
                content: "Новый файл больше 1 МБ. Third Hand не загружает его содержимое в diff viewer.",
                kind: .tooLarge,
                wasTruncated: false
            )
        }
        guard let data = try? Data(contentsOf: fileURL),
              !data.contains(0),
              let text = String(data: data, encoding: .utf8)
        else {
            return GitFileDiff(
                path: relativePath,
                content: "Новый файл является двоичным.",
                kind: .binary,
                wasTruncated: false
            )
        }

        let allLines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        let visibleLines = allLines.prefix(20_000)
        let body = visibleLines.map { "+\($0)" }.joined(separator: "\n")
        let header = """
        diff --git a/\(relativePath) b/\(relativePath)
        new file mode 100644
        --- /dev/null
        +++ b/\(relativePath)
        @@ -0,0 +1,\(allLines.count) @@
        """
        let wasTruncated = visibleLines.count < allLines.count
        return GitFileDiff(
            path: relativePath,
            content: header + "\n" + body
                + (wasTruncated ? "\n[Diff truncated by Third Hand.]" : ""),
            kind: .text,
            wasTruncated: wasTruncated
        )
    }

    private static func repositoryFingerprint(
        at repositoryURL: URL,
        hasHead: Bool,
        statusOutput: String,
        changedFiles: [ChangedFile]
    ) -> String {
        var hasher = SHA256()
        func append(_ value: String) {
            hasher.update(data: Data(value.utf8))
            hasher.update(data: Data([0]))
        }

        let fullHead = runGit(["rev-parse", "HEAD"], at: repositoryURL)
        append(fullHead.exitCode == 0 ? fullHead.stdout : "NO_HEAD")
        append(statusOutput)

        append("TRACKED_DIFF")
        updateHash(
            &hasher,
            withGitArguments: [
                "diff", "--binary", "--no-ext-diff", "--no-textconv",
                hasHead ? "HEAD" : emptyTreeHash
            ],
            at: repositoryURL
        )

        for file in changedFiles where file.status.contains("?") {
            let hash = runGit(
                ["hash-object", "--no-filters", "--", file.path],
                at: repositoryURL
            )
            append(file.path)
            append(hash.exitCode == 0 ? hash.stdout : "UNREADABLE")
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func parsePorcelain(_ output: String) -> [ChangedFile] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var files: [ChangedFile] = []
        var index = 0

        while index < records.count {
            let line = records[index]
            guard line.count >= 4 else {
                index += 1
                continue
            }

            let rawStatus = String(line.prefix(2))
            let status = rawStatus.trimmingCharacters(in: .whitespaces)
            let path = String(line.dropFirst(3))
            if !path.isEmpty {
                files.append(ChangedFile(status: status.isEmpty ? "M" : status, path: path))
            }

            index += (rawStatus.contains("R") || rawStatus.contains("C")) ? 2 : 1
        }

        return files
    }

    private static func parseNumStat(_ output: String) -> LineStats {
        var byPath: [String: LineDelta] = [:]
        var additions = 0
        var deletions = 0

        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3,
                  let added = Int(columns[0]),
                  let deleted = Int(columns[1])
            else {
                continue
            }

            let path = String(columns[2])
            additions += added
            deletions += deleted
            byPath[path] = LineDelta(additions: added, deletions: deleted)
        }

        return LineStats(byPath: byPath, additions: additions, deletions: deletions)
    }

    private static func runGit(_ arguments: [String], at directory: URL) -> CommandResult {
        let process = Process()
        let combinedOutput = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = combinedOutput
        process.standardError = combinedOutput
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) {
            _, new in new
        }

        do {
            try process.run()
            let data = combinedOutput.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            return CommandResult(
                exitCode: process.terminationStatus,
                stdout: process.terminationStatus == 0 ? output : "",
                stderr: process.terminationStatus == 0 ? "" : output
            )
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
    }

    private static func runGitLimited(
        _ arguments: [String],
        at directory: URL,
        maximumOutputBytes: Int
    ) -> LimitedCommandResult {
        let process = Process()
        let combinedOutput = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = combinedOutput
        process.standardError = combinedOutput
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) {
            _, new in new
        }

        do {
            try process.run()
            var captured = Data()
            var wasTruncated = false
            while let chunk = try combinedOutput.fileHandleForReading.read(
                upToCount: 64 * 1_024
            ), !chunk.isEmpty {
                let available = max(0, maximumOutputBytes - captured.count)
                if available > 0 {
                    captured.append(chunk.prefix(available))
                }
                if chunk.count > available {
                    wasTruncated = true
                }
            }
            process.waitUntilExit()
            let output = String(decoding: captured, as: UTF8.self)
            return LimitedCommandResult(
                result: CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: process.terminationStatus == 0 ? output : "",
                    stderr: process.terminationStatus == 0 ? "" : output
                ),
                wasTruncated: wasTruncated
            )
        } catch {
            return LimitedCommandResult(
                result: CommandResult(
                    exitCode: -1,
                    stdout: "",
                    stderr: error.localizedDescription
                ),
                wasTruncated: false
            )
        }
    }

    private static func updateHash(
        _ hasher: inout SHA256,
        withGitArguments arguments: [String],
        at directory: URL
    ) {
        let process = Process()
        let combinedOutput = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = combinedOutput
        process.standardError = combinedOutput
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) {
            _, new in new
        }

        do {
            try process.run()
            while let chunk = try combinedOutput.fileHandleForReading.read(
                upToCount: 64 * 1_024
            ), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            process.waitUntilExit()
            hasher.update(
                data: Data("EXIT:\(process.terminationStatus)".utf8)
            )
        } catch {
            hasher.update(data: Data("ERROR:\(error.localizedDescription)".utf8))
        }
        hasher.update(data: Data([0]))
    }
}

private struct LineDelta {
    let additions: Int
    let deletions: Int
}

private struct LineStats {
    let byPath: [String: LineDelta]
    let additions: Int
    let deletions: Int
}

private struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private struct LimitedCommandResult {
    let result: CommandResult
    let wasTruncated: Bool
}
