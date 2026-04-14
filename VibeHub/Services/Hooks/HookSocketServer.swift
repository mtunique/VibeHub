//
//  HookSocketServer.swift
//  VibeHub
//
//  Unix domain socket server for real-time hook events
//  Supports request/response for permission decisions
//

import Foundation
import os.log

enum HookSocketPaths {

#if APP_STORE
    private static let appGroupId = "group.mtunique.vibehub"
#endif

    static var socketPath: String {
#if APP_STORE
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            // NOTE: Unix domain socket paths have a length limit (sun_path). Keep this short.
            return url.appendingPathComponent("ci.sock").path
        }
        // Fall back to a predictable home path (may not be writable in sandbox).
        return defaultSocketPath
#else
        return defaultSocketPath
#endif
    }

    private static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibehub", isDirectory: true)
            .appendingPathComponent("ci.sock")
            .path
    }
}

/// Logger for hook socket server
private let logger = Logger(subsystem: "com.vibehub", category: "Hooks")

/// Event received from Claude Code hooks
struct HookEvent: Codable, Sendable {
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    /// Explicit CLI source string ("_source" in the payload). Injected by
    /// the Python hook via `VIBEHUB_SOURCE=<name>`, or by the OpenCode JS
    /// plugin. When nil, `supportedCLI` falls back to the sessionId prefix.
    let rawSource: String?
    /// Source process PID (Claude Code hook uses `pid`, OpenCode plugin uses `_ppid`)
    let pid: Int?
    let sourcePid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let notificationType: String?
    let message: String?
    // Extra metadata used by non-Claude sources (eg OpenCode)
    let prompt: String?
    let sessionTitle: String?
    let lastAssistantMessage: String?
    // OpenCode server address for programmatic control
    let serverPort: Int?
    let serverHostname: String?

    // Remote session metadata (set by Claude Island when ingesting via SSH)
    let remoteHostId: String?

    // SSH client source port (from SSH_CLIENT env var on remote)
    let sshClientPort: String?

    // Multiplexer detected by hook (reported as "tmux" or "zellij")
    let multiplexer: String?
    let zellijSession: String?
    let zellijPaneId: String?

    // Streaming updates from the remote hook
    let newJsonlLines: [String]?

    // cmux multiplexer identifiers. Populated when the hook runs inside a
    // cmux-hosted terminal — Python reads `CMUX_WORKSPACE_ID` and
    // `CMUX_SURFACE_ID` from its environment (inherited from Claude's
    // parent process) and forwards them. VibeHub uses these to drive
    // `cmux send --workspace X --surface Y <text>`.
    let cmuxWorkspaceId: String?
    let cmuxSurfaceId: String?

    // Error / denial context emitted by the Python hook for the five new
    // events (PostToolUseFailure, PermissionDenied, Stop, ...). Without
    // these, the payload fields get silently dropped by JSONDecoder and
    // the app loses the reason when a tool errors or a prompt is blocked.
    let toolError: String?
    let denialReason: String?
    let stopError: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, event, status, pid, tty, tool
        case rawSource = "_source"
        case sourcePid = "_ppid"
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message
        case prompt
        case sessionTitle = "session_title"
        case lastAssistantMessage = "last_assistant_message"
        case serverPort = "_server_port"
        case serverHostname = "_server_hostname"
        case remoteHostId = "_remote_host_id"
        case sshClientPort = "ssh_client_port"
        case multiplexer
        case zellijSession = "zellij_session"
        case zellijPaneId = "zellij_pane_id"
        case newJsonlLines = "new_jsonl_lines"
        case cmuxWorkspaceId = "_cmux_workspace_id"
        case cmuxSurfaceId = "_cmux_surface_id"
        case toolError = "tool_error"
        case denialReason = "denial_reason"
        case stopError = "stop_error"
    }

    /// Create a copy with updated toolUseId
    init(
        sessionId: String,
        cwd: String,
        event: String,
        status: String,
        rawSource: String? = nil,
        pid: Int?,
        sourcePid: Int? = nil,
        tty: String?,
        tool: String?,
        toolInput: [String: AnyCodable]?,
        toolUseId: String?,
        notificationType: String?,
        message: String?,
        prompt: String? = nil,
        sessionTitle: String? = nil,
        lastAssistantMessage: String? = nil,
        serverPort: Int? = nil,
        serverHostname: String? = nil,
        remoteHostId: String? = nil,
        sshClientPort: String? = nil,
        multiplexer: String? = nil,
        zellijSession: String? = nil,
        zellijPaneId: String? = nil,
        newJsonlLines: [String]? = nil,
        cmuxWorkspaceId: String? = nil,
        cmuxSurfaceId: String? = nil,
        toolError: String? = nil,
        denialReason: String? = nil,
        stopError: String? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.event = event
        self.status = status
        self.rawSource = rawSource
        self.pid = pid
        self.sourcePid = sourcePid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.notificationType = notificationType
        self.message = message
        self.prompt = prompt
        self.sessionTitle = sessionTitle
        self.lastAssistantMessage = lastAssistantMessage
        self.serverPort = serverPort
        self.serverHostname = serverHostname
        self.remoteHostId = remoteHostId
        self.sshClientPort = sshClientPort
        self.multiplexer = multiplexer
        self.zellijSession = zellijSession
        self.zellijPaneId = zellijPaneId
        self.newJsonlLines = newJsonlLines
        self.cmuxWorkspaceId = cmuxWorkspaceId
        self.cmuxSurfaceId = cmuxSurfaceId
        self.toolError = toolError
        self.denialReason = denialReason
        self.stopError = stopError
    }

    /// Resolve the source for this event:
    /// 1. Explicit `_source` field (set by modern installs via VIBEHUB_SOURCE).
    /// 2. Legacy sessionId prefix (`opencode-` / `codex-`).
    /// 3. Fallback to `.claude`.
    nonisolated var supportedCLI: SupportedCLI {
        SupportedCLI.resolve(sourceString: rawSource, sessionId: sessionId)
    }

    var sessionPhase: SessionPhase {
        if event == "PreCompact" {
            return .compacting
        }

        switch status {
        case "waiting_for_approval":
            // Note: Full PermissionContext is constructed by SessionStore, not here
            // This is just for quick phase checks
            return .waitingForApproval(PermissionContext(
                toolUseId: toolUseId ?? "",
                toolName: tool ?? "unknown",
                toolInput: toolInput,
                receivedAt: Date()
            ))
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        default:
            return .idle
        }
    }

    /// Whether this event expects a response (permission request)
    nonisolated var expectsResponse: Bool {
        event == "PermissionRequest" && status == "waiting_for_approval"
    }
}

/// Response to send back to the hook
///
/// For Claude Code hooks, only `decision` (+ optional `reason`) is used.
/// For OpenCode plugin integration, we also support:
/// - `decision == "always"` (maps to OpenCode permission reply "always")
/// - `answers` for AskUserQuestion (maps to OpenCode /question/{id}/reply)
struct HookResponse: Codable {
    let decision: String // "allow", "deny", "ask", or "always"
    let reason: String?
    let answers: [[String]]?
}

/// Pending permission request waiting for user decision
struct PendingPermission: Sendable {
    let sessionId: String
    let toolUseId: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

/// Callback for hook events
typealias HookEventHandler = @Sendable (HookEvent) -> Void

/// Callback for permission response failures (socket died)
typealias PermissionFailureHandler = @Sendable (_ sessionId: String, _ toolUseId: String) -> Void

/// Unix domain socket server that receives events from Claude Code hooks
/// Uses GCD DispatchSource for non-blocking I/O
class HookSocketServer {
    static let socketPath = HookSocketPaths.socketPath

    static let shared = HookSocketServer(socketPath: HookSocketPaths.socketPath)

    private let socketPath: String
    private let namespacePrefix: String?
    private let remoteHostId: String?

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private var permissionFailureHandler: PermissionFailureHandler?
    private let queue = DispatchQueue(label: "com.vibehub.socket", qos: .userInitiated)

    /// Pending permission requests indexed by toolUseId
    private var pendingPermissions: [String: PendingPermission] = [:]
    private let permissionsLock = NSLock()

    /// Cache tool_use_id from PreToolUse to correlate with PermissionRequest
    /// Key: "sessionId:toolName:serializedInput" -> Queue of tool_use_ids (FIFO)
    /// PermissionRequest events don't include tool_use_id, so we cache from PreToolUse
    private var toolUseIdCache: [String: [String]] = [:]
    private let cacheLock = NSLock()

    init(socketPath: String, namespacePrefix: String? = nil, remoteHostId: String? = nil) {
        self.socketPath = socketPath
        self.namespacePrefix = namespacePrefix
        self.remoteHostId = remoteHostId
    }

    /// Start the socket server
    func start(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler? = nil) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent, onPermissionFailure: onPermissionFailure)
        }
    }

    private func startServer(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler?) {
        guard serverSocket < 0 else { return }

        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure

        // Bind + listen
        let socketURL = URL(fileURLWithPath: socketPath)
        let socketDir = socketURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)

        unlink(socketPath)
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        let bindResult: Int32

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        // Make the unix socket world-connectable.
#if !APP_STORE
        chmod(socketPath, 0o777)
#endif

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    /// Stop the socket server
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil

        unlink(socketPath)

        permissionsLock.lock()
        for (_, pending) in pendingPermissions {
            close(pending.clientSocket)
        }
        pendingPermissions.removeAll()
        permissionsLock.unlock()
    }

    private func namespaced(_ event: HookEvent) -> HookEvent {
        guard let prefix = namespacePrefix, !prefix.isEmpty else {
            return event
        }

        let sid = prefix + event.sessionId
        let toolUseId = event.toolUseId.map { prefix + $0 }

        return HookEvent(
            sessionId: sid,
            cwd: event.cwd,
            event: event.event,
            status: event.status,
            rawSource: event.rawSource,
            pid: event.pid,
            sourcePid: event.sourcePid,
            tty: event.tty,
            tool: event.tool,
            toolInput: event.toolInput,
            toolUseId: toolUseId,
            notificationType: event.notificationType,
            message: event.message,
            prompt: event.prompt,
            sessionTitle: event.sessionTitle,
            lastAssistantMessage: event.lastAssistantMessage,
            serverPort: event.serverPort,
            serverHostname: event.serverHostname,
            remoteHostId: remoteHostId,
            sshClientPort: event.sshClientPort,
            multiplexer: event.multiplexer,
            zellijSession: event.zellijSession,
            zellijPaneId: event.zellijPaneId,
            newJsonlLines: event.newJsonlLines,
            cmuxWorkspaceId: event.cmuxWorkspaceId,
            cmuxSurfaceId: event.cmuxSurfaceId,
            toolError: event.toolError,
            denialReason: event.denialReason,
            stopError: event.stopError
        )
    }

    /// Respond to a pending permission request by toolUseId
    func respondToPermission(toolUseId: String, decision: String, reason: String? = nil, answers: [[String]]? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponse(toolUseId: toolUseId, decision: decision, reason: reason, answers: answers)
        }
    }

    /// Respond to permission by sessionId (finds the most recent pending for that session)
    func respondToPermissionBySession(sessionId: String, decision: String, reason: String? = nil, answers: [[String]]? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponseBySession(sessionId: sessionId, decision: decision, reason: reason, answers: answers)
        }
    }

    /// Cancel all pending permissions for a session (when Claude stops waiting)
    func cancelPendingPermissions(sessionId: String) {
        queue.async { [weak self] in
            self?.cleanupPendingPermissions(sessionId: sessionId)
        }
    }

    /// Check if there's a pending permission request for a session
    func hasPendingPermission(sessionId: String) -> Bool {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.contains { $0.sessionId == sessionId }
    }

    /// Get the pending permission details for a session (if any)
    func getPendingPermission(sessionId: String) -> (toolName: String?, toolId: String?, toolInput: [String: AnyCodable]?)? {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        guard let pending = pendingPermissions.values.first(where: { $0.sessionId == sessionId }) else {
            return nil
        }
        return (pending.event.tool, pending.toolUseId, pending.event.toolInput)
    }

    /// Cancel a specific pending permission by toolUseId (when tool completes via terminal approval)
    func cancelPendingPermission(toolUseId: String) {
        queue.async { [weak self] in
            self?.cleanupSpecificPermission(toolUseId: toolUseId)
        }
    }

    private func cleanupSpecificPermission(toolUseId: String) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            return
        }
        permissionsLock.unlock()

        logger.debug("Tool completed externally, closing socket for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
        close(pending.clientSocket)
    }

    private func cleanupPendingPermissions(sessionId: String) {
        permissionsLock.lock()
        let matching = pendingPermissions.filter { $0.value.sessionId == sessionId }
        for (toolUseId, pending) in matching {
            logger.debug("Cleaning up stale permission for \(sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
            close(pending.clientSocket)
            pendingPermissions.removeValue(forKey: toolUseId)
        }
        permissionsLock.unlock()
    }

    // MARK: - Tool Use ID Cache

    /// Encoder with sorted keys for deterministic cache keys
    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Generate cache key from event properties
    private func cacheKey(sessionId: String, toolName: String?, toolInput: [String: AnyCodable]?) -> String {
        let inputStr: String
        if let input = toolInput,
           let data = try? Self.sortedEncoder.encode(input),
           let str = String(data: data, encoding: .utf8) {
            inputStr = str
        } else {
            inputStr = "{}"
        }
        return "\(sessionId):\(toolName ?? "unknown"):\(inputStr)"
    }

    /// Cache tool_use_id from PreToolUse event (FIFO queue per key)
    private func cacheToolUseId(event: HookEvent) {
        guard let toolUseId = event.toolUseId else { return }

        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        if toolUseIdCache[key] == nil {
            toolUseIdCache[key] = []
        }
        toolUseIdCache[key]?.append(toolUseId)
        cacheLock.unlock()

        logger.debug("Cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
    }

    /// Pop and return cached tool_use_id for PermissionRequest (FIFO)
    private func popCachedToolUseId(event: HookEvent) -> String? {
        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard var queue = toolUseIdCache[key], !queue.isEmpty else {
            return nil
        }

        let toolUseId = queue.removeFirst()

        if queue.isEmpty {
            toolUseIdCache.removeValue(forKey: key)
        } else {
            toolUseIdCache[key] = queue
        }

        logger.debug("Retrieved cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
        return toolUseId
    }

    /// Clean up cache entries for a session (on session end)
    private func cleanupCache(sessionId: String) {
        cacheLock.lock()
        let keysToRemove = toolUseIdCache.keys.filter { $0.hasPrefix("\(sessionId):") }
        for key in keysToRemove {
            toolUseIdCache.removeValue(forKey: key)
        }
        cacheLock.unlock()

        if !keysToRemove.isEmpty {
            logger.debug("Cleaned up \(keysToRemove.count) cache entries for session \(sessionId.prefix(8), privacy: .public)")
        }
    }

    // MARK: - Private

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        handleClient(clientSocket)
    }

    private func handleClient(_ clientSocket: Int32) {
        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 131072)
        var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 5.0 {
            let pollResult = poll(&pollFd, 1, 50)

            if pollResult > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(clientSocket, &buffer, buffer.count)

                if bytesRead > 0 {
                    allData.append(contentsOf: buffer[0..<bytesRead])
                } else if bytesRead == 0 {
                    break
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    break
                }
            } else if pollResult == 0 {
                if !allData.isEmpty {
                    break
                }
            } else {
                break
            }
        }

        guard !allData.isEmpty else {
            close(clientSocket)
            return
        }

        let data = allData

        guard let decoded = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            logger.warning("Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")
            close(clientSocket)
            return
        }

        let event = namespaced(decoded)

        logger.debug("Received: \(event.event, privacy: .public) for \(event.sessionId.prefix(8), privacy: .public)")

        if event.event == "PreToolUse" {
            cacheToolUseId(event: event)
        }

        if event.event == "SessionEnd" {
            cleanupCache(sessionId: event.sessionId)
        }

        if event.expectsResponse {
            let toolUseId: String
            if let eventToolUseId = event.toolUseId {
                toolUseId = eventToolUseId
            } else if let cachedToolUseId = popCachedToolUseId(event: event) {
                toolUseId = cachedToolUseId
            } else {
                logger.warning("Permission request missing tool_use_id for \(event.sessionId.prefix(8), privacy: .public) - no cache hit")
                close(clientSocket)
                eventHandler?(event)
                return
            }

            logger.debug("Permission request - keeping socket open for \(event.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")

            let updatedEvent = HookEvent(
                sessionId: event.sessionId,
                cwd: event.cwd,
                event: event.event,
                status: event.status,
                rawSource: event.rawSource,
                pid: event.pid,
                sourcePid: event.sourcePid,
                tty: event.tty,
                tool: event.tool,
                toolInput: event.toolInput,
                toolUseId: toolUseId,  // Use resolved toolUseId
                notificationType: event.notificationType,
                message: event.message,
                prompt: event.prompt,
                sessionTitle: event.sessionTitle,
                lastAssistantMessage: event.lastAssistantMessage,
                serverPort: event.serverPort,
                serverHostname: event.serverHostname,
                remoteHostId: event.remoteHostId,
                sshClientPort: event.sshClientPort,
                multiplexer: event.multiplexer,
                zellijSession: event.zellijSession,
                zellijPaneId: event.zellijPaneId,
                newJsonlLines: event.newJsonlLines,
                cmuxWorkspaceId: event.cmuxWorkspaceId,
                cmuxSurfaceId: event.cmuxSurfaceId,
                toolError: event.toolError,
                denialReason: event.denialReason,
                stopError: event.stopError
            )

            let pending = PendingPermission(
                sessionId: event.sessionId,
                toolUseId: toolUseId,
                clientSocket: clientSocket,
                event: updatedEvent,
                receivedAt: Date()
            )
            permissionsLock.lock()
            pendingPermissions[toolUseId] = pending
            permissionsLock.unlock()

            eventHandler?(updatedEvent)
            return
        } else {
            close(clientSocket)
        }

        eventHandler?(event)
    }

    private func sendPermissionResponse(toolUseId: String, decision: String, reason: String?, answers: [[String]]?) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            logger.debug("No pending permission for toolUseId: \(toolUseId.prefix(12), privacy: .public)")
            return
        }
        permissionsLock.unlock()

        let response = HookResponse(decision: decision, reason: reason, answers: answers)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
            }
        }

        close(pending.clientSocket)
    }

    private func sendPermissionResponseBySession(sessionId: String, decision: String, reason: String?, answers: [[String]]?) {
        permissionsLock.lock()
        let matchingPending = pendingPermissions.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.receivedAt > $1.receivedAt }
            .first

        guard let pending = matchingPending else {
            permissionsLock.unlock()
            logger.debug("No pending permission for session: \(sessionId.prefix(8), privacy: .public)")
            return
        }

        pendingPermissions.removeValue(forKey: pending.toolUseId)
        permissionsLock.unlock()

        let response = HookResponse(decision: decision, reason: reason, answers: answers)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            permissionFailureHandler?(sessionId, pending.toolUseId)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(sessionId.prefix(8), privacy: .public) tool:\(pending.toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        var writeSuccess = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
                writeSuccess = true
            }
        }

        close(pending.clientSocket)

        if !writeSuccess {
            permissionFailureHandler?(sessionId, pending.toolUseId)
        }
    }
}

// MARK: - AnyCodable for tool_input

/// Type-erasing codable wrapper for heterogeneous values
/// Used to decode JSON objects with mixed value types
struct AnyCodable: Codable, @unchecked Sendable {
    /// The underlying value (nonisolated(unsafe) because Any is not Sendable)
    nonisolated(unsafe) let value: Any

    /// Initialize with any value
    init(_ value: Any) {
        self.value = value
    }

    /// Decode from JSON
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    /// Encode to JSON
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Cannot encode value"))
        }
    }
}
