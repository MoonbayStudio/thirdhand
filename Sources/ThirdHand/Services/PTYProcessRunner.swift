import Darwin
import Foundation

struct AgentCLIInvocation: Sendable {
    let attemptID: UUID
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String
    let environment: [String: String]
    let terminalRows: UInt16
    let terminalColumns: UInt16

    init(
        attemptID: UUID,
        executablePath: String,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String],
        terminalRows: UInt16 = 42,
        terminalColumns: UInt16 = 180
    ) {
        self.attemptID = attemptID
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.terminalRows = max(terminalRows, 1)
        self.terminalColumns = max(terminalColumns, 1)
    }
}

struct PTYProcessResult: Sendable {
    let output: String
    let exitCode: Int32
}

enum PTYProcessEvent: Sendable {
    case output(data: Data, streamWasTruncated: Bool)
    case finished(PTYProcessResult)
}

final class PTYProcessRunner: @unchecked Sendable {
    private struct Session: Sendable {
        let processID: pid_t
        let masterFileDescriptor: Int32
    }

    private var sessions: [UUID: Session] = [:]
    private var cancelledAttempts: Set<UUID> = []
    private var pendingCancellations: Set<UUID> = []
    private let stateLock = NSLock()

    func run(_ invocation: AgentCLIInvocation) async throws -> PTYProcessResult {
        var finalResult: PTYProcessResult?
        for try await event in events(invocation) {
            if case let .finished(result) = event {
                finalResult = result
            }
        }

        guard let finalResult else {
            throw AgentExecutionError.launchFailed(
                "PTY завершилась без финального состояния."
            )
        }
        return finalResult
    }

    func events(
        _ invocation: AgentCLIInvocation
    ) -> AsyncThrowingStream<PTYProcessEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.finish(
                        throwing: AgentExecutionError.launchFailed(
                            "PTY runner больше недоступен."
                        )
                    )
                    return
                }

                do {
                    let session = try self.start(invocation)
                    var didDropLiveOutput = false
                    let result = Self.collectOutput(from: session) { chunk in
                        let yieldResult = continuation.yield(
                            .output(
                                data: chunk,
                                streamWasTruncated: didDropLiveOutput
                            )
                        )
                        switch yieldResult {
                        case .enqueued:
                            didDropLiveOutput = false
                        case .dropped:
                            didDropLiveOutput = true
                        case .terminated:
                            break
                        @unknown default:
                            didDropLiveOutput = true
                        }
                    }
                    self.closePTY(
                        for: session,
                        attemptID: invocation.attemptID
                    )

                    if self.finish(attemptID: invocation.attemptID) {
                        continuation.finish(throwing: AgentExecutionError.cancelled)
                        return
                    }

                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                _ = self?.cancel(attemptID: invocation.attemptID)
            }
        }
    }

    private func start(_ invocation: AgentCLIInvocation) throws -> Session {
        stateLock.lock()
        let wasCancelledBeforeSpawn = pendingCancellations.remove(invocation.attemptID) != nil
        stateLock.unlock()
        if wasCancelledBeforeSpawn {
            throw AgentExecutionError.cancelled
        }

        let session: Session
        do {
            session = try Self.spawn(invocation)
        } catch let executionError as AgentExecutionError {
            throw executionError
        } catch {
            stateLock.lock()
            pendingCancellations.remove(invocation.attemptID)
            stateLock.unlock()
            throw AgentExecutionError.launchFailed(error.localizedDescription)
        }
        stateLock.lock()
        sessions[invocation.attemptID] = session
        let shouldCancel = pendingCancellations.remove(invocation.attemptID) != nil
        if shouldCancel {
            cancelledAttempts.insert(invocation.attemptID)
        }
        stateLock.unlock()

        if shouldCancel {
            interrupt(session, attemptID: invocation.attemptID)
        }
        return session
    }

    private func finish(attemptID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        sessions[attemptID] = nil
        pendingCancellations.remove(attemptID)
        return cancelledAttempts.remove(attemptID) != nil
    }

    @discardableResult
    func cancel(attemptID: UUID) -> Bool {
        stateLock.lock()
        guard let session = sessions[attemptID] else {
            pendingCancellations.insert(attemptID)
            stateLock.unlock()
            return true
        }
        cancelledAttempts.insert(attemptID)
        stateLock.unlock()

        interrupt(session, attemptID: attemptID)
        return true
    }

    /// Sends input to an already-running PTY session.
    ///
    /// Callers must wait for output proving that the target CLI is at the
    /// expected prompt before using this method. This avoids accidentally
    /// confirming trust, authentication, or permission dialogs.
    @discardableResult
    func sendInput(_ value: String, attemptID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let session = sessions[attemptID],
              let data = value.data(using: .utf8)
        else {
            return false
        }
        return Self.writeAll(data, to: session.masterFileDescriptor)
    }

    private func closePTY(for session: Session, attemptID: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard sessions[attemptID]?.processID == session.processID else {
            return
        }
        sessions[attemptID] = nil
        _ = Darwin.close(session.masterFileDescriptor)
    }

    private func interrupt(_ session: Session, attemptID: UUID) {
        let processGroupID = Darwin.getpgid(session.processID)
        let target = processGroupID == session.processID ? -session.processID : session.processID
        _ = Darwin.kill(target, SIGINT)
        if target != session.processID {
            _ = Darwin.kill(session.processID, SIGINT)
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self,
                  self.isCurrent(session, attemptID: attemptID)
            else {
                return
            }
            _ = Darwin.kill(target, SIGTERM)
            if target != session.processID {
                _ = Darwin.kill(session.processID, SIGTERM)
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self,
                      self.isCurrent(session, attemptID: attemptID)
                else {
                    return
                }
                _ = Darwin.kill(target, SIGKILL)
                if target != session.processID {
                    _ = Darwin.kill(session.processID, SIGKILL)
                }
            }
        }
    }

    private func isCurrent(_ session: Session, attemptID: UUID) -> Bool {
        stateLock.lock()
        let matches = sessions[attemptID]?.processID == session.processID
        stateLock.unlock()
        return matches && Darwin.kill(session.processID, 0) == 0
    }

    private static func spawn(_ invocation: AgentCLIInvocation) throws -> Session {
        let argumentStrings = [invocation.executablePath] + invocation.arguments
        let environmentStrings = invocation.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()

        let argumentStorage = try makeCStringStorage(argumentStrings)
        let environmentStorage = try makeCStringStorage(environmentStrings)
        guard let workingDirectoryPointer = strdup(invocation.workingDirectory) else {
            argumentStorage.forEach { free($0) }
            environmentStorage.forEach { free($0) }
            throw POSIXLaunchError.outOfMemory
        }

        defer {
            argumentStorage.forEach { free($0) }
            environmentStorage.forEach { free($0) }
            free(workingDirectoryPointer)
        }

        var arguments = argumentStorage.map(Optional.some) + [nil]
        var environment = environmentStorage.map(Optional.some) + [nil]
        var masterFileDescriptor: Int32 = -1
        var windowSize = winsize(
            ws_row: invocation.terminalRows,
            ws_col: invocation.terminalColumns,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        let executablePointer = argumentStorage[0]

        let processID = arguments.withUnsafeMutableBufferPointer { argumentBuffer in
            environment.withUnsafeMutableBufferPointer { environmentBuffer in
                let child = forkpty(&masterFileDescriptor, nil, nil, &windowSize)
                if child == 0 {
                    _ = Darwin.signal(SIGINT, SIG_DFL)
                    _ = Darwin.signal(SIGTERM, SIG_DFL)
                    _ = Darwin.signal(SIGHUP, SIG_DFL)
                    _ = Darwin.signal(SIGPIPE, SIG_DFL)
                    guard Darwin.chdir(workingDirectoryPointer) == 0 else {
                        _exit(126)
                    }
                    Darwin.execve(
                        executablePointer,
                        argumentBuffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                    _exit(127)
                }
                return child
            }
        }

        guard processID >= 0 else {
            throw POSIXLaunchError.systemError(errno)
        }

        return Session(
            processID: processID,
            masterFileDescriptor: masterFileDescriptor
        )
    }

    private static func makeCStringStorage(
        _ strings: [String]
    ) throws -> [UnsafeMutablePointer<CChar>] {
        var storage: [UnsafeMutablePointer<CChar>] = []
        storage.reserveCapacity(strings.count)

        for string in strings {
            guard let pointer = strdup(string) else {
                storage.forEach { free($0) }
                throw POSIXLaunchError.outOfMemory
            }
            storage.append(pointer)
        }

        return storage
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { storage in
            guard let baseAddress = storage.baseAddress else { return true }
            var offset = 0

            while offset < storage.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    storage.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var pollDescriptor = pollfd(
                        fd: descriptor,
                        events: Int16(POLLOUT),
                        revents: 0
                    )
                    guard Darwin.poll(&pollDescriptor, 1, 100) > 0 else {
                        return false
                    }
                    continue
                }
                return false
            }

            return true
        }
    }

    private static func collectOutput(
        from session: Session,
        onOutput: (Data) -> Void = { _ in }
    ) -> PTYProcessResult {
        let maximumOutputBytes = 8 * 1_024 * 1_024
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var processStatus: Int32 = 0
        var childExited = false
        var streamEnded = false

        let existingFlags = Darwin.fcntl(session.masterFileDescriptor, F_GETFL)
        if existingFlags >= 0 {
            _ = Darwin.fcntl(
                session.masterFileDescriptor,
                F_SETFL,
                existingFlags | O_NONBLOCK
            )
        }

        while !childExited {
            if !streamEnded {
                var descriptor = pollfd(
                    fd: session.masterFileDescriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
                let pollResult = Darwin.poll(&descriptor, 1, 100)
                if pollResult < 0, errno != EINTR {
                    streamEnded = true
                } else if pollResult > 0 {
                    while true {
                        let count = buffer.withUnsafeMutableBytes { bytes in
                            Darwin.read(
                                session.masterFileDescriptor,
                                bytes.baseAddress,
                                bytes.count
                            )
                        }

                        if count > 0 {
                            let chunk = Data(buffer.prefix(Int(count)))
                            output.append(chunk)
                            if output.count > maximumOutputBytes {
                                output.removeFirst(output.count - maximumOutputBytes)
                            }
                            onOutput(chunk)
                            continue
                        }

                        if count == 0 || (count < 0 && errno == EIO) {
                            streamEnded = true
                        }
                        if count < 0 && errno == EINTR {
                            continue
                        }
                        break
                    }
                }
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }

            let waitResult = Darwin.waitpid(
                session.processID,
                &processStatus,
                WNOHANG
            )
            if waitResult == session.processID {
                childExited = true
            } else if waitResult < 0, errno != EINTR {
                childExited = true
            }
        }

        // The direct child is authoritative for the invocation lifetime. A
        // detached descendant may keep the PTY slave open; drain only bytes
        // already available so it cannot hold the task or repository lease.
        while !streamEnded {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    session.masterFileDescriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            guard count > 0 else { break }
            let chunk = Data(buffer.prefix(Int(count)))
            output.append(chunk)
            if output.count > maximumOutputBytes {
                output.removeFirst(output.count - maximumOutputBytes)
            }
            onOutput(chunk)
        }
        return PTYProcessResult(
            output: String(decoding: output, as: UTF8.self),
            exitCode: normalizedExitCode(processStatus)
        )
    }

    private static func normalizedExitCode(_ processStatus: Int32) -> Int32 {
        let signal = processStatus & 0x7f
        if signal == 0 {
            return (processStatus >> 8) & 0xff
        }
        return 128 + signal
    }
}

private enum POSIXLaunchError: LocalizedError {
    case outOfMemory
    case systemError(Int32)

    var errorDescription: String? {
        switch self {
        case .outOfMemory:
            "Недостаточно памяти для запуска процесса."
        case let .systemError(code):
            String(cString: strerror(code))
        }
    }
}
