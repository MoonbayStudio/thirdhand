import SwiftUI

struct TaskChangesView: View {
    let taskTitle: String
    let repositoryPath: String

    @Environment(\.dismiss) private var dismiss
    @State private var files: [ChangedFile]
    @State private var selection: String?
    @State private var loadedDiff: GitFileDiff?
    @State private var isLoading = false
    @State private var diffRequestID = UUID()

    init(
        taskTitle: String,
        repositoryPath: String,
        files: [ChangedFile],
        initiallySelectedFile: ChangedFile? = nil
    ) {
        self.taskTitle = taskTitle
        self.repositoryPath = repositoryPath
        _files = State(initialValue: files)
        _selection = State(
            initialValue: initiallySelectedFile?.id ?? files.first?.id
        )
    }

    var body: some View {
        NavigationSplitView {
            List(files, selection: $selection) { file in
                HStack(spacing: 8) {
                    Text(file.status)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(file.statusTint)
                        .frame(width: 22)

                    Text(file.path)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .tag(file.id)
            }
            .listStyle(.sidebar)
            .navigationTitle("Изменённые файлы")
            .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 360)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedFile?.path ?? "Изменения")
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(repositoryPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button {
                        Task { await refreshChanges() }
                    } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)

                    Button("Готово") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding(14)

                Divider()

                diffContent
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .navigationTitle("Изменения · \(taskTitle)")
        .task(id: selection) {
            await loadSelectedDiff()
        }
    }

    @ViewBuilder
    private var diffContent: some View {
        if isLoading {
            ProgressView("Загрузка diff…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadedDiff {
            if loadedDiff.kind == .binary || loadedDiff.kind == .tooLarge {
                ContentUnavailableView {
                    Label(
                        loadedDiff.kind == .binary ? "Двоичный файл" : "Файл слишком большой",
                        systemImage: loadedDiff.kind == .binary
                            ? "doc.badge.ellipsis"
                            : "externaldrive.badge.exclamationmark"
                    )
                } description: {
                    Text(loadedDiff.content)
                }
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(
                            Array(diffLines(loadedDiff.content).enumerated()),
                            id: \.offset
                        ) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(diffBackground(for: line))
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(minWidth: 620, alignment: .leading)
                }
            }
        } else {
            ContentUnavailableView(
                "Выберите файл",
                systemImage: "doc.text.magnifyingglass"
            )
        }
    }

    private var selectedFile: ChangedFile? {
        files.first { $0.id == selection }
    }

    private func loadSelectedDiff() async {
        guard let selectedFile else {
            diffRequestID = UUID()
            loadedDiff = nil
            isLoading = false
            return
        }
        let selectedFileID = selectedFile.id
        let requestID = UUID()
        diffRequestID = requestID
        isLoading = true
        let diff = await GitService().fileDiff(
            at: URL(fileURLWithPath: repositoryPath),
            file: selectedFile
        )
        guard diffRequestID == requestID,
              selection == selectedFileID
        else {
            return
        }
        loadedDiff = diff
        isLoading = false
    }

    private func refreshChanges() async {
        let selectedPath = selectedFile?.path
        let requestID = UUID()
        diffRequestID = requestID
        isLoading = true

        let snapshot = await GitService().snapshot(
            at: URL(fileURLWithPath: repositoryPath)
        )
        guard diffRequestID == requestID else { return }

        files = snapshot.changedFiles
        selection = selectedPath
            .flatMap { path in files.first(where: { $0.path == path })?.id }
            ?? files.first?.id
        loadedDiff = nil

        guard selection != nil else {
            isLoading = false
            return
        }
        await loadSelectedDiff()
    }

    private func diffLines(_ content: String) -> [String] {
        content.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
    }

    private func diffBackground(for line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") {
            return .green.opacity(0.12)
        }
        if line.hasPrefix("-"), !line.hasPrefix("---") {
            return .red.opacity(0.12)
        }
        if line.hasPrefix("@@") {
            return .blue.opacity(0.10)
        }
        return .clear
    }
}
