//
//  AnderCoreService.swift
//  SideStoreSupport
//
//  AnderStore Core runs as a background process (LiveProcess) and never shows an interface.
//  This service owns its lifetime and carries every request to it through one command envelope,
//  so adding a capability means adding a command, not a new selector on both sides of XPC.
//

import Foundation

/// An error raised by Core, or while starting it. `kind` is stable and machine readable —
/// the interface turns it into a localized message, never the other way round.
public struct AnderCoreError: LocalizedError {
    public let kind: String
    public let message: String
    public let domain: String?
    public let code: Int?

    public init(kind: String, message: String, domain: String? = nil, code: Int? = nil) {
        self.kind = kind
        self.message = message
        self.domain = domain
        self.code = code
    }

    init(payload: [String: Any]) {
        self.kind = payload["kind"] as? String ?? "unknown"
        self.message = payload["message"] as? String ?? ""
        self.domain = payload["domain"] as? String
        self.code = payload["code"] as? Int
    }

    public var errorDescription: String? { message.isEmpty ? kind : message }

    public var payload: [String: Any] {
        var result: [String: Any] = ["kind": kind, "message": message]
        if let domain { result["domain"] = domain }
        if let code { result["code"] = code }
        return result
    }

    static let coreUnavailable = AnderCoreError(kind: "coreUnavailable",
                                                message: "AnderStore Core is not part of this build")
    static let notConnected = AnderCoreError(kind: "notConnected",
                                             message: "AnderStore Core is not connected")
    static let startTimeout = AnderCoreError(kind: "startTimeout",
                                             message: "AnderStore Core did not start in time")
    static let terminated = AnderCoreError(kind: "terminated",
                                           message: "AnderStore Core quit unexpectedly")
    static let noHome = AnderCoreError(kind: "noHome",
                                       message: "The AnderStore data folder is unavailable")
    static let noBundle = AnderCoreError(kind: "noBundle",
                                         message: "AnderStore Core is missing from the app bundle")
}

@MainActor
public final class AnderCoreService {

    public static let shared = AnderCoreService()

    public enum Status: String {
        case unavailable, stopped, starting, running, stopping, failed
    }

    /// Bumped when the envelope itself changes shape. Core reports its own in `handshake`.
    static let protocolVersion = 2

    /// Only these may be retried automatically after the connection dropped: everything else
    /// either talks to Apple or changes state, and a silent second attempt is how accounts get
    /// rate limited and certificates get burned.
    private static let retryableCommands: Set<String> = [
        "handshake", "snapshot", "account.status", "cert.status", "device.status"
    ]

    private struct Pending {
        let command: String
        let onEvent: (([String: Any]) -> Void)?
        let continuation: CheckedContinuation<[String: Any], Error>
    }

    public private(set) var status: Status = .stopped
    public private(set) var coreVersion: String?
    public private(set) var supportedCommands: Set<String> = []

    /// Progress target of the legacy "Refresh All Apps" intent path.
    var progress: Progress?

    private var listener: NSXPCListener?
    private var ext: NSExtension?
    private var pid: Int32 = 0
    private var launchGeneration = 0
    private var launchContinuation: CheckedContinuation<Void, Error>?
    private var startTask: Task<Void, Error>?
    private var pending: [String: Pending] = [:]
    private var legacyRefresh: CheckedContinuation<Void, Error>?
    private var idleTimer: Timer?
    private var shutdownAcknowledged = false

    private static let idleTimeout: TimeInterval = 90
    private static let launchTimeout: TimeInterval = 45

    private var client: RefreshClient? { RefreshHandler.shared.client }

    private var isProcessAlive: Bool { pid > 0 && getpgid(pid) > 0 }

    /// true when the background Core (LiveProcess extension) shipped with the app.
    nonisolated public static var isInstalled: Bool {
        guard let url = UserDefaults.lcMainBundle().builtInPlugInsURL?.appendingPathComponent("LiveProcess.appex") else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Lifetime

    public func ensureRunning() async throws {
        if status == .stopping {
            if !shutdownAcknowledged, isProcessAlive, client != nil {
                // Core has not agreed to quit yet, so this request simply cancels the shutdown.
                status = .running
                noteActivity()
                return
            }
            // It is already on its way out; finish the job rather than end up with two of them.
            ext?._kill(9)
            handleTermination(generation: launchGeneration)
        }
        if status == .running, isProcessAlive, client != nil {
            noteActivity()
            return
        }
        // A second caller must wait for the launch already in flight instead of falling
        // through to a half-started Core.
        if let startTask {
            try await startTask.value
            return
        }
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.startCore()
        }
        startTask = task
        do {
            try await task.value
            startTask = nil
        } catch {
            startTask = nil
            throw error
        }
    }

    private func startCore() async throws {
        guard Self.isInstalled else {
            status = .unavailable
            throw AnderCoreError.coreUnavailable
        }
        // Core can disappear without the interruption block firing; clear the stale connection
        // and listener before starting a new process, or the new one talks to nobody.
        if !isProcessAlive, ext != nil || client != nil {
            handleTermination(generation: launchGeneration)
        }
        status = .starting
        do {
            try await launch()
        } catch {
            status = .failed
            teardown()
            throw error
        }
        status = .running
        shutdownAcknowledged = false
        noteActivity()
        // The handshake is the authoritative liveness check and tells us what this Core can do.
        // A Core built from an older commit simply reports fewer commands.
        if let response = try? await sendRequest("handshake",
                                                 params: ["protocolVersion": Self.protocolVersion],
                                                 onEvent: nil) {
            coreVersion = response["coreVersion"] as? String
            supportedCommands = Set(response["supportedCommands"] as? [String] ?? [])
        }
    }

    private func launch() async throws {
        if listener == nil {
            guard let listener = startAnonymousListener(RefreshHandler.shared) else {
                throw AnderCoreError.notConnected
            }
            self.listener = listener
        }
        guard let listener = self.listener else { throw AnderCoreError.notConnected }

        guard let lcHomeC = getenv("LC_HOME_PATH") else { throw AnderCoreError.noHome }
        let lcHome = String(cString: lcHomeC)
        // The Core home folder does not exist until Core runs for the first time.
        let coreHomeURL = URL(fileURLWithPath: lcHome).appendingPathComponent("Documents/SideStore")
        try? FileManager.default.createDirectory(at: coreHomeURL, withIntermediateDirectories: true)
        guard let bookmarkData = bookmarkForURL(coreHomeURL) else { throw AnderCoreError.noHome }

        let extensionItem = NSExtensionItem()
        extensionItem.userInfo = [
            "selected": "builtinSideStore",
            "bookmarks": [bookmarkData],
            "endpoint": listener.endpoint
        ]

        guard let liveProcessURL = UserDefaults.lcMainBundle().builtInPlugInsURL?.appendingPathComponent("LiveProcess.appex"),
              let liveProcessBundle = Bundle(url: liveProcessURL),
              let liveProcessID = liveProcessBundle.bundleIdentifier
        else {
            throw AnderCoreError.noBundle
        }

        let extensionInstance: NSExtension
        do {
            extensionInstance = try NSExtension(identifier: liveProcessID)
        } catch {
            throw AnderCoreError(kind: "noBundle", message: error.localizedDescription)
        }
        self.ext = extensionInstance

        launchGeneration &+= 1
        let generation = launchGeneration

        extensionInstance.setRequestInterruptionBlock { _ in
            Task { @MainActor in
                AnderCoreService.shared.handleTermination(generation: generation)
            }
        }

        let uuid = await extensionInstance.beginRequest(withInputItems: [extensionItem])
        pid = extensionInstance.pid(forRequestIdentifier: uuid)

        // The timeout belongs to this launch only: without the generation check a timer left
        // over from an earlier attempt would kill the process that replaced it.
        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.launchTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            AnderCoreService.shared.failLaunch(generation: generation)
        }
        defer { timeout.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            launchContinuation = continuation
        }
    }

    private func failLaunch(generation: Int) {
        guard generation == launchGeneration, let continuation = launchContinuation else { return }
        launchContinuation = nil
        ext?._kill(9)
        continuation.resume(throwing: AnderCoreError.startTimeout)
    }

    /// Asks Core to save its data and quit. Core refuses while it is in the middle of an
    /// operation, and then nothing happens — we do not kill a process that is signing.
    public func shutdown(reason: String) {
        guard status == .running, let client else { return }
        status = .stopping
        shutdownAcknowledged = false
        idleTimer?.invalidate()
        idleTimer = nil
        client.shutdown(reason: reason)

        let generation = launchGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            AnderCoreService.shared.finishShutdown(generation: generation)
        }
    }

    private func finishShutdown(generation: Int) {
        guard generation == launchGeneration, status == .stopping else { return }
        if shutdownAcknowledged {
            // Core agreed to quit but is still around — make sure it is gone.
            if isProcessAlive { ext?._kill(9) }
            handleTermination(generation: generation)
        } else {
            // Core refused (it is busy). Leave it running and try again later.
            status = .running
            noteActivity()
        }
    }

    private func teardown() {
        listener?.invalidate()
        listener = nil
        ext = nil
        pid = 0
        RefreshHandler.shared.client = nil
        idleTimer?.invalidate()
        idleTimer = nil
    }

    // MARK: - Requests

    @discardableResult
    public func perform(_ command: String,
                        params: [String: Any] = [:],
                        onEvent: (([String: Any]) -> Void)? = nil) async throws -> [String: Any] {
        try await ensureRunning()
        if !supportedCommands.isEmpty, !supportedCommands.contains(command) {
            throw AnderCoreError(kind: "unsupportedCommand",
                                 message: "This version of AnderStore Core cannot do that yet")
        }
        do {
            return try await sendRequest(command, params: params, onEvent: onEvent)
        } catch let error as AnderCoreError
                    where (error.kind == "terminated" || error.kind == "notConnected")
                    && Self.retryableCommands.contains(command) {
            try await ensureRunning()
            return try await sendRequest(command, params: params, onEvent: onEvent)
        }
    }

    private func sendRequest(_ command: String,
                             params: [String: Any],
                             onEvent: (([String: Any]) -> Void)?) async throws -> [String: Any] {
        guard let client else { throw AnderCoreError.notConnected }
        var request = params
        request["cmd"] = command
        let requestID = UUID().uuidString
        noteActivity()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            pending[requestID] = Pending(command: command, onEvent: onEvent, continuation: continuation)
            client.performRequest(request, requestID: requestID)
        }
    }

    /// The legacy "Refresh All Apps" intent path, still driven by its own selector.
    func performLegacyRefresh(identifier: String, mangledName: String) async throws {
        if legacyRefresh != nil {
            throw AnderCoreError(kind: "busy", message: "Another refresh is already running")
        }
        try await ensureRunning()
        guard let client else { throw AnderCoreError.notConnected }
        noteActivity()
        client.refreshAllApps(withIdentifier: identifier, mangledTypeName: mangledName)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            legacyRefresh = continuation
        }
    }

    // MARK: - Idle

    private func noteActivity() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTimeout, repeats: false) { _ in
            Task { @MainActor in AnderCoreService.shared.shutdownIfIdle() }
        }
    }

    private func shutdownIfIdle() {
        guard pending.isEmpty, legacyRefresh == nil, startTask == nil, status == .running else {
            noteActivity()
            return
        }
        shutdown(reason: "idle")
    }

    // MARK: - Callbacks from RefreshHandler (XPC)

    func handleFinishedLaunching() {
        launchContinuation?.resume()
        launchContinuation = nil
    }

    func handleConnectionLost() {
        handleTermination(generation: launchGeneration)
    }

    func handleTermination(generation: Int) {
        // An interruption from a process we already replaced must not disturb the current one.
        guard generation == launchGeneration else { return }
        // Tearing down invalidates the listener, which calls back in here; stop the second pass.
        guard status != .stopped || ext != nil || !pending.isEmpty || legacyRefresh != nil else { return }
        pid = 0
        status = .stopped
        RefreshHandler.shared.client = nil
        if let continuation = launchContinuation {
            launchContinuation = nil
            continuation.resume(throwing: AnderCoreError.terminated)
        }
        if let continuation = legacyRefresh {
            legacyRefresh = nil
            continuation.resume(throwing: AnderCoreError.terminated)
        }
        let inFlight = pending
        pending.removeAll()
        for entry in inFlight.values {
            entry.continuation.resume(throwing: AnderCoreError.terminated)
        }
        teardown()
    }

    func handleEvent(requestID: String, event: [String: Any]) {
        pending[requestID]?.onEvent?(event)
    }

    func handleFinish(requestID: String, response: [String: Any]?, error: [String: Any]?) {
        guard let entry = pending.removeValue(forKey: requestID) else { return }
        noteActivity()
        if let error {
            entry.continuation.resume(throwing: AnderCoreError(payload: error))
        } else {
            entry.continuation.resume(returning: response ?? [:])
        }
    }

    func handleWillShutdown(reason: String) {
        shutdownAcknowledged = true
    }

    func handleLegacyProgress(_ value: Double) {
        progress?.completedUnitCount = Int64(value * 100)
    }

    func handleLegacyFinish(_ error: String?) {
        guard let continuation = legacyRefresh else { return }
        legacyRefresh = nil
        noteActivity()
        if let error {
            continuation.resume(throwing: AnderCoreError(kind: "refreshFailed", message: error))
        } else {
            continuation.resume()
        }
    }
}
