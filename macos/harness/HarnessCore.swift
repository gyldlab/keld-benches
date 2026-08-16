import AppKit
import CryptoKit
import Darwin
import Foundation

let harnessSchemaVersion = 6
let harnessVersion = "0.6.0"

@inline(__always)
func monotonicNowNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

enum HarnessError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case io(String)
    case launch(String)
    case foregroundInterference(ForegroundFailureReason)
    case protocolViolation(String)
    case timeout(String)
    case measurement(String)

    var description: String {
        switch self {
        case .invalidArgument(let message):
            return "invalid argument: \(message)"
        case .io(let message):
            return "I/O failure: \(message)"
        case .launch(let message):
            return "launch failure: \(message)"
        case .foregroundInterference(let reason):
            return "foreground interference: \(reason.rawValue)"
        case .protocolViolation(let message):
            return "benchmark protocol violation: \(message)"
        case .timeout(let message):
            return "benchmark timeout: \(message)"
        case .measurement(let message):
            return "measurement failure: \(message)"
        }
    }
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let stdoutData: Data
    let stderrData: Data

    init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        stdoutData = Data(stdout.utf8)
        stderrData = Data(stderr.utf8)
    }

    init(status: Int32, stdoutData: Data, stderrData: Data) {
        self.status = status
        stdout = String(decoding: stdoutData, as: UTF8.self)
        stderr = String(decoding: stderrData, as: UTF8.self)
        self.stdoutData = stdoutData
        self.stderrData = stderrData
    }
}

private final class CommandDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func store(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

func runCommand(
    _ executable: String,
    _ arguments: [String],
    currentDirectoryURL: URL? = nil,
    timeoutSeconds: Double = 15
) throws -> CommandResult {
    guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 300 else {
        throw HarnessError.invalidArgument("command timeout must be finite and in (0, 300]")
    }
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL
    if URL(fileURLWithPath: executable).lastPathComponent == "git" {
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": "/var/empty",
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
        ]
    } else {
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment
    }
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        throw HarnessError.io("could not run \(executable): \(error)")
    }

    let outputGroup = DispatchGroup()
    let stdoutBox = CommandDataBox()
    let stderrBox = CommandDataBox()
    outputGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stdoutBox.store(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        outputGroup.leave()
    }
    outputGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stderrBox.store(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        outputGroup.leave()
    }
    let termination = DispatchSemaphore(value: 0)
    let commandDeadline = DispatchTime.now() + timeoutSeconds
    process.terminationHandler = { _ in termination.signal() }
    if termination.wait(timeout: commandDeadline) == .timedOut {
        process.terminate()
        if termination.wait(timeout: .now() + 1) == .timedOut {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            if termination.wait(timeout: .now() + 1) == .timedOut {
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
            }
        }
        _ = outputGroup.wait(timeout: .now() + 1)
        throw HarnessError.timeout(
            "command \(URL(fileURLWithPath: executable).lastPathComponent) exceeded its deadline"
        )
    }
    if outputGroup.wait(timeout: .now() + 2) == .timedOut {
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        _ = outputGroup.wait(timeout: .now() + 1)
        throw HarnessError.timeout(
            "command \(URL(fileURLWithPath: executable).lastPathComponent) output did not drain before its deadline"
        )
    }
    let stdoutData = stdoutBox.load()
    let stderrData = stderrBox.load()
    return CommandResult(
        status: process.terminationStatus,
        stdoutData: stdoutData,
        stderrData: stderrData
    )
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func rawGitBlobObjectId(_ data: Data, hexadecimalLength: Int) -> String? {
    var framed = Data("blob \(data.count)\u{0}".utf8)
    framed.append(data)
    switch hexadecimalLength {
    case 40:
        return Insecure.SHA1.hash(data: framed).map { String(format: "%02x", $0) }.joined()
    case 64:
        return SHA256.hash(data: framed).map { String(format: "%02x", $0) }.joined()
    default:
        return nil
    }
}

func kernelProcessStartIdentity(for pid: Int32) throws -> String? {
    var information = proc_bsdinfo()
    errno = 0
    let byteCount = proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        &information,
        Int32(MemoryLayout<proc_bsdinfo>.size)
    )
    if byteCount == 0, errno == ESRCH {
        return nil
    }
    guard byteCount == Int32(MemoryLayout<proc_bsdinfo>.size) else {
        let errorNumber = errno
        throw HarnessError.measurement(
            "proc_pidinfo(\(pid), PROC_PIDTBSDINFO) returned \(byteCount) bytes, errno \(errorNumber)"
        )
    }
    return "\(information.pbi_start_tvsec).\(String(format: "%06llu", information.pbi_start_tvusec))"
}

struct KernelLaunchOwnership: Equatable {
    let pid: Int32
    let uniqueId: UInt64
    let pidVersion: UInt32
    let resourceCoalitionId: UInt64
}

struct KernelProcessUniqueIdentity: Equatable {
    let uniqueId: UInt64
    let pidVersion: UInt32
}

/// Internal process-generation key used to reason about foreground ownership.
/// It is deliberately not `Codable`: benchmark JSON may expose only stable
/// booleans and reason codes, never foreground application identities.
struct ForegroundProcessGeneration: Equatable, Sendable {
    let pid: Int32
    let uniqueId: UInt64
    let pidVersion: UInt32
}

struct ForegroundSampleLease: Equatable, Sendable {
    let id: UInt64
    let startCursor: Int
}

struct ForegroundSessionCursorState {
    let anchor: ForegroundProcessGeneration
    private(set) var committedCursor: Int
    private(set) var activeLease: ForegroundSampleLease?
    private var nextLeaseId: UInt64 = 1

    init(anchor: ForegroundProcessGeneration, committedCursor: Int) {
        self.anchor = anchor
        self.committedCursor = committedCursor
    }

    mutating func beginSample() -> ForegroundSampleLease? {
        guard activeLease == nil else { return nil }
        let lease = ForegroundSampleLease(
            id: nextLeaseId,
            startCursor: committedCursor
        )
        nextLeaseId &+= 1
        activeLease = lease
        return lease
    }

    func owns(_ lease: ForegroundSampleLease) -> Bool {
        activeLease == lease
    }

    mutating func commit(_ lease: ForegroundSampleLease, cursor: Int) -> Bool {
        guard activeLease == lease,
              cursor >= lease.startCursor,
              cursor >= committedCursor else {
            return false
        }
        committedCursor = cursor
        return true
    }

    mutating func end(_ lease: ForegroundSampleLease) -> Bool {
        guard activeLease == lease else { return false }
        activeLease = nil
        return true
    }

    mutating func sealTail(cursor: Int) -> Bool {
        guard activeLease == nil, cursor >= committedCursor else { return false }
        committedCursor = cursor
        return true
    }
}

enum ForegroundFailureReason: String, Codable, Equatable, Sendable {
    case anchorUnavailable = "foreground_anchor_unavailable"
    case anchorGenerationUnavailable = "foreground_anchor_generation_unavailable"
    case anchorChangedBeforeLaunch = "foreground_anchor_changed_before_launch"
    case targetGenerationUnavailable = "foreground_target_generation_unavailable"
    case activationGenerationUnavailable = "foreground_activation_generation_unavailable"
    case foreignApplicationBeforeTarget = "foreground_foreign_application_before_target"
    case targetLostToForeignBeforeBeacon = "foreground_target_lost_to_foreign_before_beacon"
    case anchorReboundedBeforeBeacon = "foreground_anchor_rebounded_before_beacon"
    case targetNeverActive = "foreground_target_never_active"
    case targetNotActiveAtBeacon = "foreground_target_not_active_at_beacon"
    case sessionContinuityUnavailable = "foreground_session_continuity_unavailable"
    case anchorExitedBeforeRestoration = "foreground_anchor_exited_before_restoration"
    case anchorGenerationChangedBeforeRestoration = "foreground_anchor_generation_changed_before_restoration"
    case anchorNotRestoredBeforeDeadline = "foreground_anchor_not_restored_before_deadline"
}

enum ForegroundAnchorGenerationStatus: Equatable, Sendable {
    case sameGeneration
    case exited
    case reused
}

/// Pure foreground-transition contract. The AppKit observer feeds this state
/// machine generation-bound activation events; no NSWorkspace policy is hidden
/// in the integration layer.
struct ForegroundTransitionState {
    let anchor: ForegroundProcessGeneration
    private(set) var target: ForegroundProcessGeneration?
    private(set) var current: ForegroundProcessGeneration
    private(set) var targetActivatedBeforeBeacon = false
    private(set) var transitionUninterruptedBeforeBeacon = false
    private(set) var beaconAccepted = false
    private(set) var exactAnchorRestoredAfterCleanup = false
    private(set) var failureReason: ForegroundFailureReason?

    init(anchor: ForegroundProcessGeneration) {
        self.anchor = anchor
        current = anchor
    }

    mutating func reject(_ reason: ForegroundFailureReason) {
        if failureReason == nil { failureReason = reason }
        if !beaconAccepted { transitionUninterruptedBeforeBeacon = false }
    }

    mutating func prepareForLaunch(current generation: ForegroundProcessGeneration?) {
        guard failureReason == nil else { return }
        guard generation == anchor else {
            reject(.anchorChangedBeforeLaunch)
            return
        }
        current = anchor
    }

    mutating func observeBetweenSampleActivation(
        _ generation: ForegroundProcessGeneration?
    ) {
        guard failureReason == nil else { return }
        guard let generation else {
            reject(.activationGenerationUnavailable)
            return
        }
        guard generation == anchor else {
            reject(.anchorChangedBeforeLaunch)
            return
        }
        current = anchor
    }

    mutating func bindTarget(_ generation: ForegroundProcessGeneration?) {
        guard failureReason == nil else { return }
        guard let generation, generation != anchor else {
            reject(.targetGenerationUnavailable)
            return
        }
        target = generation
    }

    mutating func activationGenerationWasUnavailable() {
        guard !beaconAccepted else { return }
        reject(.activationGenerationUnavailable)
    }

    mutating func observeActivation(_ generation: ForegroundProcessGeneration) {
        guard !beaconAccepted, failureReason == nil else { return }
        guard generation != current else { return }
        guard let target else {
            reject(.targetGenerationUnavailable)
            return
        }

        if current == anchor {
            if generation == target {
                current = target
                targetActivatedBeforeBeacon = true
            } else {
                reject(.foreignApplicationBeforeTarget)
            }
            return
        }

        if current == target {
            if generation == anchor {
                reject(.anchorReboundedBeforeBeacon)
            } else {
                reject(.targetLostToForeignBeforeBeacon)
            }
        }
    }

    mutating func acceptBeacon(targetReportsActive: Bool) {
        guard failureReason == nil else { return }
        guard let target, targetActivatedBeforeBeacon, current == target else {
            reject(.targetNeverActive)
            return
        }
        guard targetReportsActive else {
            reject(.targetNotActiveAtBeacon)
            return
        }
        beaconAccepted = true
        transitionUninterruptedBeforeBeacon = true
    }

    @discardableResult
    mutating func observeAnchorRestoration(
        current generation: ForegroundProcessGeneration?,
        anchorStatus: ForegroundAnchorGenerationStatus
    ) -> Bool {
        switch anchorStatus {
        case .exited:
            reject(.anchorExitedBeforeRestoration)
            return false
        case .reused:
            reject(.anchorGenerationChangedBeforeRestoration)
            return false
        case .sameGeneration:
            exactAnchorRestoredAfterCleanup = generation == anchor
            return exactAnchorRestoredAfterCleanup
        }
    }

    @discardableResult
    mutating func observeCommittedAnchorRestoration(
        current generation: ForegroundProcessGeneration?,
        anchorStatus: ForegroundAnchorGenerationStatus,
        sessionCommitAccepted: Bool
    ) -> Bool {
        guard sessionCommitAccepted else {
            reject(.sessionContinuityUnavailable)
            return false
        }
        return observeAnchorRestoration(
            current: generation,
            anchorStatus: anchorStatus
        )
    }

    mutating func restorationTimedOut() {
        guard !exactAnchorRestoredAfterCleanup else { return }
        reject(.anchorNotRestoredBeforeDeadline)
    }
}

// Mirrors XNU bsd/sys/proc_info_private.h's 56-byte
// proc_uniqidentifierinfo. Named fields avoid treating a mixed-width C
// structure as an array of UInt64 words.
private struct KernelProcUniqueIdentifierInfo {
    var executableUuidLow: UInt64 = 0
    var executableUuidHigh: UInt64 = 0
    var uniqueId: UInt64 = 0
    var parentUniqueId: UInt64 = 0
    var pidVersion: Int32 = 0
    var originalParentPidVersion: Int32 = 0
    var reserved2: UInt64 = 0
    var reserved3: UInt64 = 0
}

func kernelProcessUniqueIdentity(for pid: Int32) throws -> KernelProcessUniqueIdentity? {
    guard MemoryLayout<KernelProcUniqueIdentifierInfo>.size == 56 else {
        throw HarnessError.measurement("unsupported proc_uniqidentifierinfo ABI layout")
    }
    var information = KernelProcUniqueIdentifierInfo()
    errno = 0
    let byteCount = withUnsafeMutablePointer(to: &information) { pointer in
        proc_pidinfo(
            pid,
            17, // PROC_PIDUNIQIDENTIFIERINFO
            0,
            UnsafeMutableRawPointer(pointer),
            Int32(MemoryLayout<KernelProcUniqueIdentifierInfo>.size)
        )
    }
    if byteCount == 0, errno == ESRCH { return nil }
    guard byteCount == Int32(MemoryLayout<KernelProcUniqueIdentifierInfo>.size) else {
        let errorNumber = errno
        throw HarnessError.measurement(
            "proc_pidinfo(\(pid), PROC_PIDUNIQIDENTIFIERINFO) returned \(byteCount) bytes, errno \(errorNumber)"
        )
    }
    let identity = KernelProcessUniqueIdentity(
        uniqueId: information.uniqueId,
        pidVersion: UInt32(bitPattern: information.pidVersion)
    )
    guard identity.uniqueId != 0, identity.pidVersion != 0 else {
        throw HarnessError.measurement(
            "proc_pidinfo(\(pid), PROC_PIDUNIQIDENTIFIERINFO) returned an invalid process generation"
        )
    }
    return identity
}

func signalProcessGeneration(
    pid: Int32,
    identity: KernelProcessUniqueIdentity,
    signal: Int32
) throws -> Bool {
    var auditToken = audit_token_t(val: (
        0, 0, 0, 0, 0,
        UInt32(bitPattern: pid),
        0,
        identity.pidVersion
    ))
    let status = proc_signal_with_audittoken(&auditToken, signal)
    if status == 0 { return true }
    if status == ESRCH { return false }
    throw HarnessError.measurement(
        "generation-bound signal \(signal) for PID \(pid) failed with errno \(status)"
    )
}

private typealias ProcInfoExtendedIdFunction = @convention(c) (
    Int32,
    Int32,
    UInt32,
    UInt32,
    UInt64,
    UInt64,
    UnsafeMutableRawPointer?,
    Int32
) -> Int32

private let procInfoExtendedIdFunction: ProcInfoExtendedIdFunction? = {
    guard let symbol = Darwin.dlsym(
        UnsafeMutableRawPointer(bitPattern: -2),
        "__proc_info_extended_id"
    ) else { return nil }
    return unsafeBitCast(symbol, to: ProcInfoExtendedIdFunction.self)
}()

private func generationBoundProcessInfo(
    pid: Int32,
    flavor: UInt32,
    uniqueId: UInt64,
    buffer: UnsafeMutableRawPointer?,
    byteCount: Int32
) throws -> Int32 {
    guard let query = procInfoExtendedIdFunction else {
        throw HarnessError.measurement(
            "this macOS build does not export __proc_info_extended_id; generation-bound launch ownership is unsupported"
        )
    }
    errno = 0
    let result = query(
        2, // PROC_INFO_CALL_PIDINFO
        pid,
        flavor,
        0x02, // PIF_COMPARE_UNIQUEID
        uniqueId,
        0,
        buffer,
        byteCount
    )
    if result < 0, errno == ESRCH { return 0 }
    guard result >= 0 else {
        let errorNumber = errno
        throw HarnessError.measurement(
            "generation-bound proc info for PID \(pid), flavor \(flavor) failed with errno \(errorNumber)"
        )
    }
    return result
}

func kernelLaunchOwnership(for pid: Int32) throws -> KernelLaunchOwnership? {
    guard let uniqueIdentity = try kernelProcessUniqueIdentity(for: pid) else { return nil }
    // PROC_PIDCOALITIONINFO (private flavor 20) returns resource and jetsam
    // coalition IDs followed by three reserved words. It is used here because
    // it is an in-process kernel query at the launch callback ownership
    // boundary; spawning launchctl before the beacon would perturb the score.
    // The extended call binds the query to the captured 64-bit process unique
    // ID, so PID reuse cannot substitute a foreign coalition.
    var coalitionInfo = [UInt64](repeating: 0, count: 5)
    let byteCount = try coalitionInfo.withUnsafeMutableBytes { buffer in
        try generationBoundProcessInfo(
            pid: pid,
            flavor: 20,
            uniqueId: uniqueIdentity.uniqueId,
            buffer: buffer.baseAddress,
            byteCount: Int32(buffer.count)
        )
    }
    if byteCount == 0 { return nil }
    guard byteCount == Int32(coalitionInfo.count * MemoryLayout<UInt64>.size),
          coalitionInfo[0] != 0 else {
        throw HarnessError.measurement(
            "generation-bound PROC_PIDCOALITIONINFO for PID \(pid) returned \(byteCount) bytes"
        )
    }

    return KernelLaunchOwnership(
        pid: pid,
        uniqueId: uniqueIdentity.uniqueId,
        pidVersion: uniqueIdentity.pidVersion,
        resourceCoalitionId: coalitionInfo[0]
    )
}

private func updateBundleHashField(_ field: Data, hasher: inout SHA256) {
    var length = UInt64(field.count).littleEndian
    withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
    hasher.update(data: field)
}

private func updateBundleHashRecord(
    kind: String,
    relativePath: String,
    permissions: UInt16,
    payload: Data,
    hasher: inout SHA256
) {
    updateBundleHashField(Data(kind.utf8), hasher: &hasher)
    updateBundleHashField(Data(relativePath.utf8), hasher: &hasher)
    updateBundleHashField(Data(String(permissions).utf8), hasher: &hasher)
    updateBundleHashField(payload, hasher: &hasher)
}

/// Hash a bundle as a sorted sequence of relative path, file kind, and bytes.
/// This avoids non-deterministic archive timestamps while still identifying the
/// exact `.app` tree that was launched.
func bundleTreeSha256(_ root: URL) throws -> String {
    let fileManager = FileManager.default
    func information(at url: URL) throws -> stat {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else {
            throw HarnessError.io("lstat failed for bundle entry: \(String(cString: strerror(errno)))")
        }
        return value
    }
    func permissions(_ value: stat) -> UInt16 {
        UInt16(value.st_mode & mode_t(0o7777))
    }

    let rootInformation = try information(at: root)
    guard rootInformation.st_mode & S_IFMT == S_IFDIR else {
        throw HarnessError.io("app bundle root is not a directory")
    }
    var pendingDirectories = [(url: root, relativePath: "")]
    var entries: [(url: URL, relativePath: String)] = []
    while let directory = pendingDirectories.popLast() {
        let names = try fileManager.contentsOfDirectory(atPath: directory.url.path).sorted()
        for name in names {
            let child = directory.url.appendingPathComponent(name)
            let relative = directory.relativePath.isEmpty
                ? name
                : directory.relativePath + "/" + name
            let childInformation = try information(at: child)
            entries.append((url: child, relativePath: relative))
            if childInformation.st_mode & S_IFMT == S_IFDIR {
                pendingDirectories.append((url: child, relativePath: relative))
            }
        }
    }

    var hasher = SHA256()
    updateBundleHashRecord(
        kind: "directory",
        relativePath: ".",
        permissions: permissions(rootInformation),
        payload: Data(),
        hasher: &hasher
    )
    for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
        let entryInformation = try information(at: entry.url)
        let type = entryInformation.st_mode & S_IFMT
        if type == S_IFLNK {
            let destination = try fileManager.destinationOfSymbolicLink(atPath: entry.url.path)
            updateBundleHashRecord(
                kind: "link",
                relativePath: entry.relativePath,
                permissions: permissions(entryInformation),
                payload: Data(destination.utf8),
                hasher: &hasher
            )
        } else if type == S_IFREG {
            updateBundleHashRecord(
                kind: "file",
                relativePath: entry.relativePath,
                permissions: permissions(entryInformation),
                payload: try Data(contentsOf: entry.url, options: .mappedIfSafe),
                hasher: &hasher
            )
        } else if type == S_IFDIR {
            updateBundleHashRecord(
                kind: "directory",
                relativePath: entry.relativePath,
                permissions: permissions(entryInformation),
                payload: Data(),
                hasher: &hasher
            )
        } else {
            throw HarnessError.io("unsupported file kind in app bundle: \(entry.relativePath)")
        }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

struct BeaconReceipt: Codable, Equatable {
    let token: String
    let receivedMonotonicNanoseconds: UInt64
    let clientNowMilliseconds: Double?
    let scriptStartMilliseconds: Double?
    let firstRafMilliseconds: Double?
    let secondRafMilliseconds: Double?
    let documentVisibilityState: String?
    let documentHadFocus: Bool?
    let peerAddress: String
}

struct ServerEvent: Codable, Equatable {
    let monotonicNanoseconds: UInt64
    let requestTarget: String
    let kind: String
    let status: Int
    let accepted: Bool
    let reason: String
    let presentedToken: String?
}

private struct HTTPReply {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data
}

/// A one-purpose HTTP/1.1 server. It only listens on IPv4 loopback, serves the
/// canonical hello document, and accepts one nonce-correlated paint beacon per
/// run. The nonce prevents stale-run attribution; it is not a security boundary
/// against other processes owned by the same trusted benchmark user.
final class LoopbackBeaconServer: @unchecked Sendable {
    private struct ClientHandlerWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let html: Data
    private let socketFileDescriptor: Int32
    private let acceptQueue = DispatchQueue(label: "com.keld.benches.harness.http")
    private let clientQueue = DispatchQueue(label: "com.keld.benches.harness.clients", attributes: .concurrent)
    private let timeoutQueue = DispatchQueue(label: "com.keld.benches.harness.timeout")
    private let lock = NSLock()
    private var stopped = false
    private var acceptFailure: String?

    private var expectedToken: String?
    private var staleTokens = Set<String>()
    private var activeTokenTimedOut = false
    private var htmlServed = false
    private var receipt: BeaconReceipt?
    private var waiter: CheckedContinuation<BeaconReceipt, Error>?
    private var waiterDeadlineNanoseconds: UInt64?
    private var eventsByToken: [String: [ServerEvent]] = [:]
    private var activeClientHandlers = 0
    private var clientHandlerWaiters: [ClientHandlerWaiter] = []

    let port: UInt16

    init(html: Data) throws {
        self.html = html

        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw HarnessError.io("socket(AF_INET, SOCK_STREAM) failed: \(String(cString: strerror(errno)))")
        }
        socketFileDescriptor = descriptor

        var reuse: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            Darwin.close(descriptor)
            throw HarnessError.io("setsockopt(SO_REUSEADDR) failed: \(String(cString: strerror(errno)))")
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(descriptor)
            throw HarnessError.io("bind(127.0.0.1:0) failed: \(String(cString: strerror(errno)))")
        }

        guard Darwin.listen(descriptor, 16) == 0 else {
            Darwin.close(descriptor)
            throw HarnessError.io("listen failed: \(String(cString: strerror(errno)))")
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &boundLength)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            throw HarnessError.io("getsockname failed: \(String(cString: strerror(errno)))")
        }
        port = UInt16(bigEndian: boundAddress.sin_port)

        acceptQueue.async { [weak self] in
            self?.acceptConnections()
        }
    }

    deinit {
        stop()
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let pending = waiter
        waiter = nil
        waiterDeadlineNanoseconds = nil
        let handlerWaiters = clientHandlerWaiters
        clientHandlerWaiters.removeAll()
        lock.unlock()

        pending?.resume(throwing: HarnessError.io("loopback server stopped"))
        for handlerWaiter in handlerWaiters {
            handlerWaiter.continuation.resume(throwing: HarnessError.io("loopback server stopped"))
        }
        Darwin.shutdown(socketFileDescriptor, SHUT_RDWR)
        Darwin.close(socketFileDescriptor)
    }

    func activate(token: String) throws {
        guard UUID(uuidString: token) != nil else {
            throw HarnessError.invalidArgument("run token must be a UUID")
        }

        lock.lock()
        if let acceptFailure {
            lock.unlock()
            throw HarnessError.io(acceptFailure)
        }
        if let oldToken = expectedToken {
            staleTokens.insert(oldToken)
        }
        let oldWaiter = waiter
        waiter = nil
        expectedToken = token
        htmlServed = false
        receipt = nil
        activeTokenTimedOut = false
        waiterDeadlineNanoseconds = nil
        eventsByToken[token] = []
        lock.unlock()

        oldWaiter?.resume(throwing: HarnessError.protocolViolation("run superseded by a new token"))
    }

    func finish(token: String) {
        lock.lock()
        guard expectedToken == token else {
            lock.unlock()
            return
        }
        staleTokens.insert(token)
        expectedToken = nil
        activeTokenTimedOut = false
        let pending = waiter
        waiter = nil
        waiterDeadlineNanoseconds = nil
        lock.unlock()
        pending?.resume(throwing: HarnessError.protocolViolation("run ended before a paint beacon arrived"))
    }

    func url(for token: String) -> URL {
        // UUID tokens consist only of URL-path-safe ASCII.
        URL(string: "http://127.0.0.1:\(port)/run/\(token)/hello.html?token=\(token)")!
    }

    func events(for token: String) -> [ServerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return eventsByToken[token] ?? []
    }

    func activeClientHandlerCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activeClientHandlers
    }

    func quiesceClientHandlers(deadlineNanoseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let waiterId = UUID()
            lock.lock()
            if activeClientHandlers == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                clientHandlerWaiters.append(ClientHandlerWaiter(
                    id: waiterId,
                    continuation: continuation
                ))
                let now = monotonicNowNanoseconds()
                let remaining = deadlineNanoseconds > now ? deadlineNanoseconds - now : 0
                lock.unlock()
                timeoutQueue.asyncAfter(
                    deadline: .now() + .nanoseconds(Int(clamping: remaining))
                ) { [weak self] in
                    self?.timeoutClientHandlerWaiter(id: waiterId)
                }
            }
        }
    }

    func awaitBeacon(token: String, deadlineNanoseconds: UInt64) async throws -> BeaconReceipt {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let acceptFailure {
                lock.unlock()
                continuation.resume(throwing: HarnessError.io(acceptFailure))
                return
            }
            guard expectedToken == token else {
                lock.unlock()
                continuation.resume(throwing: HarnessError.protocolViolation("token is no longer active"))
                return
            }
            if let receipt {
                lock.unlock()
                if receipt.receivedMonotonicNanoseconds <= deadlineNanoseconds {
                    continuation.resume(returning: receipt)
                } else {
                    continuation.resume(throwing: HarnessError.timeout("paint-opportunity beacon arrived after deadline"))
                }
                return
            }
            guard waiter == nil else {
                lock.unlock()
                continuation.resume(throwing: HarnessError.protocolViolation("multiple waiters for one run"))
                return
            }
            waiter = continuation
            waiterDeadlineNanoseconds = deadlineNanoseconds
            let now = monotonicNowNanoseconds()
            let remaining = deadlineNanoseconds > now ? deadlineNanoseconds - now : 0
            lock.unlock()

            timeoutQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: remaining))) { [weak self] in
                self?.timeout(token: token)
            }
        }
    }

    private func timeout(token: String) {
        lock.lock()
        guard expectedToken == token, receipt == nil, let pending = waiter else {
            lock.unlock()
            return
        }
        waiter = nil
        activeTokenTimedOut = true
        lock.unlock()
        pending.resume(throwing: HarnessError.timeout("no valid double-rAF beacon for token \(token)"))
    }

    private func timeoutClientHandlerWaiter(id: UUID) {
        lock.lock()
        guard let index = clientHandlerWaiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let waiter = clientHandlerWaiters.remove(at: index)
        let unfinishedCount = activeClientHandlers
        lock.unlock()
        waiter.continuation.resume(throwing: HarnessError.timeout(
            "\(unfinishedCount) loopback client handler(s) remained active at the quiescence deadline"
        ))
    }

    private func failAcceptLoop(_ message: String) {
        lock.lock()
        if acceptFailure == nil { acceptFailure = message }
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(throwing: HarnessError.io(message))
    }

    private func acceptConnections() {
        while true {
            var peer = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.accept(socketFileDescriptor, socketAddress, &length)
                }
            }

            if client < 0 {
                let errorNumber = errno
                lock.lock()
                let shouldStop = stopped
                lock.unlock()
                if shouldStop { return }
                if errorNumber == EINTR || errorNumber == ECONNABORTED { continue }
                failAcceptLoop("loopback accept failed with errno \(errorNumber)")
                return
            }

            var noSignal: Int32 = 1
            guard setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                Darwin.close(client)
                failAcceptLoop("could not configure accepted loopback socket")
                return
            }
            var socketTimeout = timeval(tv_sec: 1, tv_usec: 0)
            guard setsockopt(
                client,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &socketTimeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0,
            setsockopt(
                client,
                SOL_SOCKET,
                SO_SNDTIMEO,
                &socketTimeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else {
                Darwin.close(client)
                failAcceptLoop("could not configure accepted loopback socket timeouts")
                return
            }
            let peerAddress = Self.describe(peer: peer)
            lock.lock()
            activeClientHandlers += 1
            lock.unlock()
            clientQueue.async { [weak self] in
                defer { self?.clientHandlerFinished() }
                self?.handle(client: client, peerAddress: peerAddress)
                Darwin.close(client)
            }
        }
    }

    private func clientHandlerFinished() {
        lock.lock()
        activeClientHandlers -= 1
        let waiters = activeClientHandlers == 0 ? clientHandlerWaiters : []
        if activeClientHandlers == 0 { clientHandlerWaiters.removeAll() }
        lock.unlock()
        for waiter in waiters { waiter.continuation.resume() }
    }

    private func handle(client: Int32, peerAddress: String) {
        guard let requestHead = Self.readRequestHead(from: client),
              let firstLine = requestHead.components(separatedBy: "\r\n").first else {
            Self.write(reply: HTTPReply(status: 400, reason: "Bad Request", contentType: "text/plain", body: Data()), to: client)
            return
        }

        let fields = firstLine.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard fields.count == 3 else {
            Self.write(reply: HTTPReply(status: 400, reason: "Bad Request", contentType: "text/plain", body: Data()), to: client)
            return
        }
        guard fields[0] == "GET" else {
            Self.write(reply: HTTPReply(status: 405, reason: "Method Not Allowed", contentType: "text/plain", body: Data()), to: client)
            return
        }
        guard fields[2] == "HTTP/1.1" else {
            Self.write(reply: HTTPReply(status: 400, reason: "Bad Request", contentType: "text/plain", body: Data()), to: client)
            return
        }

        let target = String(fields[1])
        let reply = evaluate(target: target, peerAddress: peerAddress)
        Self.write(reply: reply, to: client)
    }

    private func evaluate(target: String, peerAddress: String) -> HTTPReply {
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
            return reject(target: target, kind: "malformed", status: 400, reason: "malformed request target", token: nil)
        }
        let tokenItems = (components.queryItems ?? []).filter { $0.name == "token" }
        guard tokenItems.count == 1, let presentedToken = tokenItems[0].value, !presentedToken.isEmpty else {
            return reject(target: target, kind: "correlation", status: 400, reason: "missing or ambiguous run token", token: nil)
        }

        lock.lock()
        let activeToken = expectedToken
        let isStale = staleTokens.contains(presentedToken)
        let activeTimedOut = activeTokenTimedOut
        lock.unlock()

        guard presentedToken == activeToken else {
            return reject(
                target: target,
                kind: "correlation",
                status: isStale ? 410 : 403,
                reason: isStale ? "stale token" : "wrong token",
                token: presentedToken
            )
        }
        guard !activeTimedOut else {
            return reject(target: target, kind: "correlation", status: 408, reason: "run token timed out", token: presentedToken)
        }

        let pathParts = components.path.split(separator: "/").map(String.init)
        if pathParts.count == 3, pathParts[0] == "run", pathParts[2] == "hello.html" {
            guard pathParts[1] == presentedToken else {
                return reject(target: target, kind: "html", status: 403, reason: "URL path token does not match query token", token: presentedToken)
            }

            lock.lock()
            guard expectedToken == presentedToken else {
                lock.unlock()
                return reject(target: target, kind: "correlation", status: 410, reason: "token changed during request", token: presentedToken)
            }
            let duplicate = htmlServed
            if !duplicate { htmlServed = true }
            if !duplicate {
                appendEventLocked(
                    target: target,
                    kind: "html",
                    status: 200,
                    accepted: true,
                    reason: "canonical document served",
                    token: presentedToken,
                    runToken: presentedToken
                )
            }
            lock.unlock()
            if duplicate {
                return reject(target: target, kind: "html", status: 409, reason: "duplicate HTML request", token: presentedToken)
            }
            return HTTPReply(status: 200, reason: "OK", contentType: "text/html; charset=utf-8", body: html)
        }

        if components.path == "/beacon.gif" {
            let phases = (components.queryItems ?? []).filter { $0.name == "phase" }.compactMap(\.value)
            guard phases == ["double-raf"] else {
                return reject(target: target, kind: "beacon", status: 422, reason: "missing or invalid double-rAF phase", token: presentedToken)
            }

            let clientNow = Self.uniqueQueryValue("client_now_ms", components: components).flatMap(Double.init)
            let scriptStart = Self.uniqueQueryValue("script_start_ms", components: components).flatMap(Double.init)
            let firstRaf = Self.uniqueQueryValue("raf1_ms", components: components).flatMap(Double.init)
            let secondRaf = Self.uniqueQueryValue("raf2_ms", components: components).flatMap(Double.init)
            let visibility = Self.uniqueQueryValue("visibility", components: components)
            let hadFocus = Self.uniqueQueryValue("focus", components: components).flatMap { value in
                value == "true" ? true : value == "false" ? false : nil
            }
            guard let clientNow, let scriptStart, let firstRaf, let secondRaf,
                  visibility == "visible", hadFocus == true,
                  clientNow.isFinite, scriptStart.isFinite, firstRaf.isFinite, secondRaf.isFinite,
                  scriptStart >= 0,
                  scriptStart <= firstRaf,
                  firstRaf <= secondRaf,
                  secondRaf <= clientNow else {
                return reject(
                    target: target,
                    kind: "beacon",
                    status: 422,
                    reason: "invalid, hidden, unfocused, duplicate, or unordered rendering-opportunity diagnostics",
                    token: presentedToken
                )
            }

            lock.lock()
            guard expectedToken == presentedToken else {
                lock.unlock()
                return reject(target: target, kind: "correlation", status: 410, reason: "token changed during request", token: presentedToken)
            }
            guard !activeTokenTimedOut else {
                lock.unlock()
                return reject(target: target, kind: "correlation", status: 408, reason: "run token timed out", token: presentedToken)
            }
            guard htmlServed else {
                lock.unlock()
                return reject(target: target, kind: "beacon", status: 428, reason: "canonical HTML was not served first", token: presentedToken)
            }
            guard receipt == nil else {
                lock.unlock()
                return reject(target: target, kind: "beacon", status: 409, reason: "duplicate paint beacon", token: presentedToken)
            }
            let acceptedReceipt = BeaconReceipt(
                token: presentedToken,
                receivedMonotonicNanoseconds: monotonicNowNanoseconds(),
                clientNowMilliseconds: clientNow,
                scriptStartMilliseconds: scriptStart,
                firstRafMilliseconds: firstRaf,
                secondRafMilliseconds: secondRaf,
                documentVisibilityState: visibility,
                documentHadFocus: hadFocus,
                peerAddress: peerAddress
            )
            if let deadline = waiterDeadlineNanoseconds,
               acceptedReceipt.receivedMonotonicNanoseconds > deadline {
                lock.unlock()
                return reject(target: target, kind: "beacon", status: 408, reason: "beacon arrived after deadline", token: presentedToken)
            }
            receipt = acceptedReceipt
            let pending = waiter
            waiter = nil
            waiterDeadlineNanoseconds = nil
            appendEventLocked(
                target: target,
                kind: "beacon",
                status: 204,
                accepted: true,
                reason: "paint-opportunity beacon accepted",
                token: presentedToken,
                runToken: presentedToken
            )
            lock.unlock()

            pending?.resume(returning: acceptedReceipt)
            return HTTPReply(status: 204, reason: "No Content", contentType: "image/gif", body: Data())
        }

        return reject(target: target, kind: "route", status: 404, reason: "unknown route", token: presentedToken)
    }

    private func reject(target: String, kind: String, status: Int, reason: String, token: String?) -> HTTPReply {
        record(target: target, kind: kind, status: status, accepted: false, reason: reason, token: token)
        return HTTPReply(status: status, reason: Self.httpReason(status), contentType: "text/plain; charset=utf-8", body: Data("\(reason)\n".utf8))
    }

    private func record(target: String, kind: String, status: Int, accepted: Bool, reason: String, token: String?) {
        lock.lock()
        let runToken = token ?? "unattributed"
        appendEventLocked(
            target: target,
            kind: kind,
            status: status,
            accepted: accepted,
            reason: reason,
            token: token,
            runToken: runToken
        )
        lock.unlock()
    }

    private func appendEventLocked(
        target: String,
        kind: String,
        status: Int,
        accepted: Bool,
        reason: String,
        token: String?,
        runToken: String
    ) {
        let event = ServerEvent(
            monotonicNanoseconds: monotonicNowNanoseconds(),
            requestTarget: target,
            kind: kind,
            status: status,
            accepted: accepted,
            reason: reason,
            presentedToken: token
        )
        eventsByToken[runToken, default: []].append(event)
    }

    private static func readRequestHead(from client: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)
        while data.count < 16_384 {
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(Int(count)))
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard data.range(of: Data("\r\n\r\n".utf8)) != nil else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(reply: HTTPReply, to client: Int32) {
        let header = "HTTP/1.1 \(reply.status) \(reply.reason)\r\n" +
            "Content-Type: \(reply.contentType)\r\n" +
            "Content-Length: \(reply.body.count)\r\n" +
            "Cache-Control: no-store, no-cache, must-revalidate\r\n" +
            "Connection: close\r\n\r\n"
        var bytes = Data(header.utf8)
        bytes.append(reply.body)
        bytes.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.send(client, pointer, remaining, 0)
                if written <= 0 { return }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    private static func describe(peer: sockaddr_storage) -> String {
        var mutablePeer = peer
        let peerLength = socklen_t(mutablePeer.ss_len)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &mutablePeer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getnameinfo(
                    socketAddress,
                    peerLength,
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }
        return result == 0 ? String(cString: host) : "unknown"
    }

    private static func httpReason(_ status: Int) -> String {
        switch status {
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 408: return "Request Timeout"
        case 422: return "Unprocessable Content"
        case 428: return "Precondition Required"
        default: return "Rejected"
        }
    }

    private static func uniqueQueryValue(_ name: String, components: URLComponents) -> String? {
        let values = (components.queryItems ?? []).filter { $0.name == name }
        guard values.count == 1 else { return nil }
        return values[0].value
    }
}

struct CoalitionIdentity: Codable, Equatable {
    let id: UInt64
    let name: String
    let bundleIdentifier: String?
    let activeCount: Int?
}

struct ProcessMeasurement: Codable, Equatable {
    let pid: Int32
    let parentPid: Int32
    let startIdentity: String
    let uniqueId: UInt64
    let rssKiB: UInt64
    let classification: String
    let commandSha256: String

    var stableIdentity: StableProcessIdentity {
        StableProcessIdentity(
            pid: pid,
            parentPid: parentPid,
            startIdentity: startIdentity,
            uniqueId: uniqueId,
            commandSha256: commandSha256
        )
    }
}

struct StableProcessIdentity: Codable, Equatable, Hashable {
    let pid: Int32
    let parentPid: Int32
    let startIdentity: String
    let uniqueId: UInt64
    let commandSha256: String?

    static func == (lhs: StableProcessIdentity, rhs: StableProcessIdentity) -> Bool {
        lhs.pid == rhs.pid && lhs.uniqueId == rhs.uniqueId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(uniqueId)
    }
}

struct CoalitionSnapshot: Codable, Equatable {
    let identity: CoalitionIdentity
    let lifecycleCounters: CoalitionLifecycleCounters
    let processes: [ProcessMeasurement]
    let rssByClassificationKiB: [String: UInt64]
    let totalRssKiB: UInt64
    let observedMonotonicNanoseconds: UInt64
}

struct CoalitionLifecycleCounters: Codable, Equatable {
    let tasksStarted: UInt64
    let tasksExited: UInt64
}

struct ProcessRow: Equatable {
    let pid: Int32
    let parentPid: Int32
    let rssKiB: UInt64
    let startIdentity: String
    let uniqueId: UInt64
    let command: String

    func hasSameStableIdentity(as other: ProcessRow) -> Bool {
        stableIdentity == other.stableIdentity
    }

    var stableIdentity: StableProcessIdentity {
        StableProcessIdentity(
            pid: pid,
            parentPid: parentPid,
            startIdentity: startIdentity,
            uniqueId: uniqueId,
            commandSha256: sha256Hex(Data(command.utf8))
        )
    }
}

private typealias CoalitionInfoPidListFunction = @convention(c) (
    UInt64,
    UnsafeMutableRawPointer?,
    UnsafeMutablePointer<Int>?
) -> Int32

private typealias CoalitionInfoResourceUsageFunction = @convention(c) (
    UInt64,
    UnsafeMutableRawPointer?,
    Int
) -> Int32

struct CoalitionProcessSetChanged: Error {
    let message: String
}

final class ResourceCoalitionReader: Sendable {

    func identity(for pid: Int32) throws -> CoalitionIdentity {
        try Self.launchctlIdentity(for: pid)
    }

    func processIdentity(for pid: Int32) throws -> StableProcessIdentity {
        guard let row = try readProcessRowsByPid(for: [pid])[pid] else {
            throw HarnessError.measurement("PID \(pid) is not live")
        }
        return row.stableIdentity
    }

    func processIsSameAndLive(_ identity: StableProcessIdentity) throws -> Bool {
        guard let uniqueIdentity = try kernelProcessUniqueIdentity(for: identity.pid) else {
            return false
        }
        return uniqueIdentity.uniqueId == identity.uniqueId
    }

    func snapshot(
        for pid: Int32,
        expectedProcessIdentity: StableProcessIdentity,
        expectedCoalitionId: UInt64
    ) throws -> CoalitionSnapshot {
        let mainBeforeLookup = try processRow(for: pid)
        guard mainBeforeLookup.stableIdentity == expectedProcessIdentity else {
            throw HarnessError.measurement("launched process generation changed before coalition lookup")
        }
        let launchctl = try Self.launchctlIdentity(for: pid)
        guard launchctl.id == expectedCoalitionId else {
            throw HarnessError.measurement("launched process belongs to an unexpected resource coalition")
        }
        let mainAfterLookup = try processRow(for: pid)
        guard mainBeforeLookup.hasSameStableIdentity(as: mainAfterLookup),
              mainAfterLookup.stableIdentity == expectedProcessIdentity else {
            throw HarnessError.measurement("launched process generation changed during coalition lookup")
        }

        let lifecycleBefore = try Self.kernelCoalitionLifecycleCounters(id: launchctl.id)
        let memberPidsBefore = Set(try Self.kernelCoalitionMemberPids(id: launchctl.id))
        guard memberPidsBefore.contains(pid) else {
            throw CoalitionProcessSetChanged(message: "main PID was absent from its resource coalition")
        }

        // The middle ps read is the one and only RSS snapshot. Kernel coalition
        // lists and a second ps identity read bracket it so membership churn or
        // PID reuse invalidates the entire observation instead of undercounting.
        let rssRows = try readProcessRowsByPid(for: memberPidsBefore)
        let observedNanoseconds = monotonicNowNanoseconds()
        let memberPidsAfterRss = Set(try Self.kernelCoalitionMemberPids(id: launchctl.id))
        let identityRows = try readProcessRowsByPid(for: memberPidsAfterRss)
        let memberPidsAfterIdentity = Set(try Self.kernelCoalitionMemberPids(id: launchctl.id))
        let lifecycleAfter = try Self.kernelCoalitionLifecycleCounters(id: launchctl.id)
        guard memberPidsBefore == memberPidsAfterRss,
              memberPidsBefore == memberPidsAfterIdentity,
              lifecycleBefore == lifecycleAfter else {
            throw CoalitionProcessSetChanged(message: "resource-coalition membership changed around the RSS snapshot")
        }

        var members: [ProcessMeasurement] = []
        members.reserveCapacity(memberPidsBefore.count)
        for memberPid in memberPidsBefore.sorted() {
            guard let row = rssRows[memberPid],
                  let identityRow = identityRows[memberPid],
                  row.hasSameStableIdentity(as: identityRow) else {
                throw CoalitionProcessSetChanged(
                    message: "coalition PID \(memberPid) vanished or was reused around the RSS snapshot"
                )
            }
            members.append(ProcessMeasurement(
                pid: row.pid,
                parentPid: row.parentPid,
                startIdentity: row.startIdentity,
                uniqueId: row.uniqueId,
                rssKiB: row.rssKiB,
                classification: Self.classify(row: row, mainPid: pid),
                commandSha256: sha256Hex(Data(row.command.utf8))
            ))
        }

        guard members.contains(where: { $0.stableIdentity == expectedProcessIdentity }) else {
            throw HarnessError.measurement("launched process generation changed around the RSS snapshot")
        }

        var byClass: [String: UInt64] = [:]
        for member in members {
            byClass[member.classification, default: 0] += member.rssKiB
        }
        return CoalitionSnapshot(
            identity: launchctl,
            lifecycleCounters: lifecycleAfter,
            processes: members,
            rssByClassificationKiB: byClass,
            totalRssKiB: members.reduce(0) { $0 + $1.rssKiB },
            observedMonotonicNanoseconds: observedNanoseconds
        )
    }

    func awaitStableSnapshot(
        for pid: Int32,
        expectedProcessIdentity: StableProcessIdentity,
        expectedCoalitionId: UInt64,
        deadlineNanoseconds: UInt64,
        requiredConsecutiveObservations: Int,
        rssToleranceKiB: UInt64,
        requiredStableNanoseconds: UInt64
    ) async throws -> (snapshot: CoalitionSnapshot, observations: Int) {
        precondition(requiredConsecutiveObservations > 0)
        var previous: CoalitionSnapshot?
        var consecutive = 0
        var stableSince: UInt64?
        var minimumRssKiB: UInt64?
        var maximumRssKiB: UInt64?
        var observations = 0

        while monotonicNowNanoseconds() < deadlineNanoseconds {
            let current: CoalitionSnapshot
            do {
                current = try snapshot(
                    for: pid,
                    expectedProcessIdentity: expectedProcessIdentity,
                    expectedCoalitionId: expectedCoalitionId
                )
            } catch is CoalitionProcessSetChanged {
                previous = nil
                consecutive = 0
                stableSince = nil
                minimumRssKiB = nil
                maximumRssKiB = nil
                await nextObservationTick()
                continue
            }
            guard current.observedMonotonicNanoseconds <= deadlineNanoseconds,
                  monotonicNowNanoseconds() <= deadlineNanoseconds else {
                throw HarnessError.timeout("resource coalition snapshot completed after deadline")
            }
            observations += 1
            if let previous {
                let sameMembers = previous.lifecycleCounters == current.lifecycleCounters
                    && previous.processes.map(\.stableIdentity) == current.processes.map(\.stableIdentity)
                let candidateMinimum = min(minimumRssKiB ?? current.totalRssKiB, current.totalRssKiB)
                let candidateMaximum = max(maximumRssKiB ?? current.totalRssKiB, current.totalRssKiB)
                if sameMembers, candidateMaximum - candidateMinimum <= rssToleranceKiB {
                    consecutive += 1
                    minimumRssKiB = candidateMinimum
                    maximumRssKiB = candidateMaximum
                } else {
                    consecutive = 1
                    stableSince = current.observedMonotonicNanoseconds
                    minimumRssKiB = current.totalRssKiB
                    maximumRssKiB = current.totalRssKiB
                }
            } else {
                consecutive = 1
                stableSince = current.observedMonotonicNanoseconds
                minimumRssKiB = current.totalRssKiB
                maximumRssKiB = current.totalRssKiB
            }
            let stableDuration = current.observedMonotonicNanoseconds - (stableSince ?? current.observedMonotonicNanoseconds)
            if consecutive >= requiredConsecutiveObservations, stableDuration >= requiredStableNanoseconds {
                return (current, observations)
            }
            previous = current
            await nextObservationTick()
        }
        throw HarnessError.timeout("resource coalition for PID \(pid) did not stabilize")
    }

    func coalitionIsEmpty(id: UInt64) throws -> Bool {
        try coalitionMemberPids(id: id).isEmpty
    }

    func coalitionMemberPids(id: UInt64) throws -> [Int32] {
        try Self.kernelCoalitionMemberPids(id: id)
    }

    func coalitionLifecycleCounters(id: UInt64) throws -> CoalitionLifecycleCounters {
        try Self.kernelCoalitionLifecycleCounters(id: id)
    }

    func hardTerminateCoalitionMembers(id: UInt64) throws -> Int {
        let members = try Self.kernelCoalitionMemberPids(id: id)
        guard !members.contains(getpid()) else {
            throw HarnessError.measurement("refusing to terminate the harness's own resource coalition")
        }
        var signaled = 0
        for pid in members {
            guard let uniqueIdentity = try kernelProcessUniqueIdentity(for: pid) else { continue }
            guard try kernelProcessUniqueIdentity(for: pid) == uniqueIdentity,
                  try Self.kernelCoalitionMemberPids(id: id).contains(pid) else {
                continue
            }

            // XNU validates PID + pidVersion atomically, so PID reuse cannot
            // redirect this signal to a different process generation.
            if try signalProcessGeneration(pid: pid, identity: uniqueIdentity, signal: SIGKILL) {
                signaled += 1
            }
        }
        return signaled
    }

    private func readProcessRows(for requestedPids: Set<Int32>) throws -> [ProcessRow] {
        guard !requestedPids.isEmpty else { return [] }
        let pidList = requestedPids.sorted().map(String.init).joined(separator: ",")
        let result = try runCommand(
            "/bin/ps",
            ["-p", pidList, "-o", "pid=,ppid=,rss=,lstart=,command="]
        )
        if result.status == 1,
           result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        guard result.status == 0 else {
            throw HarnessError.measurement("ps failed (\(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return try Self.parseProcessRows(result.stdout)
    }

    private func readProcessRowsByPid(for requestedPids: Set<Int32>) throws -> [Int32: ProcessRow] {
        let startsBefore = try Self.kernelStartIdentities(for: requestedPids)
        let uniqueBefore = try Self.kernelUniqueIdentities(for: requestedPids)
        var rowsByPid: [Int32: ProcessRow] = [:]
        for row in try readProcessRows(for: requestedPids) {
            guard let startBefore = startsBefore[row.pid],
                  let uniqueIdentityBefore = uniqueBefore[row.pid] else {
                throw CoalitionProcessSetChanged(message: "PID \(row.pid) appeared during the process snapshot")
            }
            let stableRow = ProcessRow(
                pid: row.pid,
                parentPid: row.parentPid,
                rssKiB: row.rssKiB,
                startIdentity: startBefore,
                uniqueId: uniqueIdentityBefore.uniqueId,
                command: row.command
            )
            guard rowsByPid.updateValue(stableRow, forKey: stableRow.pid) == nil else {
                throw HarnessError.measurement("ps returned duplicate PID \(row.pid)")
            }
        }
        let startsAfter = try Self.kernelStartIdentities(for: requestedPids)
        let uniqueAfter = try Self.kernelUniqueIdentities(for: requestedPids)
        for (pid, row) in rowsByPid {
            guard startsAfter[pid] == row.startIdentity,
                  uniqueAfter[pid]?.uniqueId == row.uniqueId else {
                throw CoalitionProcessSetChanged(message: "PID \(pid) exited or was reused during the process snapshot")
            }
        }
        return rowsByPid
    }

    private static func kernelStartIdentities(for pids: Set<Int32>) throws -> [Int32: String] {
        var result: [Int32: String] = [:]
        result.reserveCapacity(pids.count)
        for pid in pids {
            if let startIdentity = try kernelProcessStartIdentity(for: pid) {
                result[pid] = startIdentity
            }
        }
        return result
    }

    private static func kernelUniqueIdentities(
        for pids: Set<Int32>
    ) throws -> [Int32: KernelProcessUniqueIdentity] {
        var result: [Int32: KernelProcessUniqueIdentity] = [:]
        result.reserveCapacity(pids.count)
        for pid in pids {
            if let identity = try kernelProcessUniqueIdentity(for: pid) {
                result[pid] = identity
            }
        }
        return result
    }

    private func processRow(for pid: Int32) throws -> ProcessRow {
        guard let row = try readProcessRowsByPid(for: [pid])[pid] else {
            throw HarnessError.measurement("PID \(pid) is not live")
        }
        return row
    }

    private static func kernelCoalitionMemberPids(id: UInt64) throws -> [Int32] {
        guard let symbol = Darwin.dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "coalition_info_pid_list"
        ) else {
            throw HarnessError.measurement(
                "this macOS build does not export coalition_info_pid_list; exact coalition RSS is unsupported"
            )
        }
        let listPids = unsafeBitCast(symbol, to: CoalitionInfoPidListFunction.self)
        var capacity = 16
        let maximumCapacity = 16_384
        while capacity <= maximumCapacity {
            var pids = [Int32](repeating: 0, count: capacity)
            var byteCount = capacity * MemoryLayout<Int32>.size
            let status = pids.withUnsafeMutableBytes { buffer in
                listPids(id, buffer.baseAddress, &byteCount)
            }
            guard status == 0 else {
                throw HarnessError.measurement(
                    "coalition_info_pid_list(\(id)) failed with status \(status)"
                )
            }
            guard byteCount >= 0,
                  byteCount <= capacity * MemoryLayout<Int32>.size,
                  byteCount.isMultiple(of: MemoryLayout<Int32>.size) else {
                throw HarnessError.measurement(
                    "coalition_info_pid_list(\(id)) returned an invalid byte count"
                )
            }
            if byteCount == capacity * MemoryLayout<Int32>.size {
                capacity *= 2
                continue
            }
            let count = byteCount / MemoryLayout<Int32>.size
            let result = Array(pids.prefix(count))
            return try validatedCoalitionPids(result, id: id, byteCount: byteCount)
        }
        throw HarnessError.measurement(
            "coalition_info_pid_list(\(id)) exceeded \(maximumCapacity) members"
        )
    }

    static func validatedCoalitionPids(
        _ result: [Int32],
        id: UInt64,
        byteCount: Int
    ) throws -> [Int32] {
        let sample = result.prefix(32).map(String.init).joined(separator: ",")
        guard result.allSatisfy({ $0 > 0 }) else {
            throw HarnessError.measurement(
                "coalition_info_pid_list(\(id)) returned a nonpositive PID "
                    + "(bytes=\(byteCount), sample=[\(sample)])"
            )
        }
        guard Set(result).count == result.count else {
            // During task exit the private kernel list can briefly expose the
            // same BSD PID twice (two process generations cannot be represented
            // by a PID-only result). That observation is unusable, but it is
            // membership churn rather than a stable API failure. Callers must
            // discard the entire observation and establish a fresh bracket.
            throw CoalitionProcessSetChanged(
                message: "coalition_info_pid_list(\(id)) changed during enumeration "
                    + "(bytes=\(byteCount), sample=[\(sample)])"
            )
        }
        return result.sorted()
    }

    private static func kernelCoalitionLifecycleCounters(id: UInt64) throws -> CoalitionLifecycleCounters {
        guard let symbol = Darwin.dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "coalition_info_resource_usage"
        ) else {
            throw HarnessError.measurement(
                "this macOS build does not export coalition_info_resource_usage; lifecycle-stable RSS is unsupported"
            )
        }
        let resourceUsage = unsafeBitCast(symbol, to: CoalitionInfoResourceUsageFunction.self)
        // The public XNU structure begins with these two counters. A generously
        // sized zeroed buffer is forward-compatible with appended fields; the
        // wrapper accepts a caller-supplied byte count and the kernel fills the
        // fields it knows.
        var usage = [UInt64](repeating: 0, count: 64)
        errno = 0
        let status = usage.withUnsafeMutableBytes { buffer in
            resourceUsage(id, buffer.baseAddress, buffer.count)
        }
        guard status == 0 else {
            let errorNumber = errno
            throw HarnessError.measurement(
                "coalition_info_resource_usage(\(id)) failed with status \(status), errno \(errorNumber)"
            )
        }
        return CoalitionLifecycleCounters(tasksStarted: usage[0], tasksExited: usage[1])
    }

    static func parseLaunchctlIdentity(_ output: String) throws -> CoalitionIdentity {
        var insideResourceCoalition = false
        var id: UInt64?
        var name: String?
        var bundleIdentifier: String?
        var activeCount: Int?

        for rawLine in output.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "resource coalition = {" {
                insideResourceCoalition = true
                continue
            }
            guard insideResourceCoalition else { continue }
            if line == "}" { break }
            let pieces = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2 else { continue }
            switch pieces[0] {
            case "ID": id = UInt64(pieces[1])
            case "name": name = pieces[1]
            case "bundle ID": bundleIdentifier = pieces[1]
            case "active count": activeCount = Int(pieces[1])
            default: break
            }
        }

        guard let id, let name else {
            throw HarnessError.measurement("launchctl output did not contain a resource coalition")
        }
        return CoalitionIdentity(id: id, name: name, bundleIdentifier: bundleIdentifier, activeCount: activeCount)
    }

    private static func launchctlIdentity(for pid: Int32) throws -> CoalitionIdentity {
        let result = try runCommand("/bin/launchctl", ["print", "pid/\(pid)"])
        guard result.status == 0 else {
            throw HarnessError.measurement("launchctl print pid/\(pid) failed")
        }
        return try parseLaunchctlIdentity(result.stdout)
    }

    static func parseProcessRows(_ output: String) throws -> [ProcessRow] {
        var rows: [ProcessRow] = []
        for rawLine in output.split(whereSeparator: { $0.isNewline }) {
            let fields = rawLine.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 9,
                  let pid = Int32(fields[0]),
                  let parentPid = Int32(fields[1]),
                  let rssKiB = UInt64(fields[2]) else {
                throw HarnessError.measurement("could not account for ps row: \(rawLine)")
            }
            rows.append(ProcessRow(
                pid: pid,
                parentPid: parentPid,
                rssKiB: rssKiB,
                startIdentity: fields[3...7].joined(separator: " "),
                uniqueId: 0,
                command: String(fields[8])
            ))
        }
        return rows
    }

    private static func classify(row: ProcessRow, mainPid: Int32) -> String {
        if row.pid == mainPid { return "host" }
        let lower = row.command.lowercased()
        if lower.contains("com.apple.webkit.webcontent") { return "web_content" }
        if lower.contains("com.apple.webkit.networking") { return "web_network" }
        if lower.contains("com.apple.webkit.gpu") { return "web_gpu" }
        if lower.contains("chromium") && lower.contains("renderer") { return "chromium_renderer" }
        if lower.contains("chromium") && lower.contains("gpu") { return "chromium_gpu" }
        if lower.contains("electron helper") || lower.contains("nwjs helper") { return "framework_helper" }
        if lower.contains("/bun") || lower.hasSuffix(" bun") { return "runtime_bun" }
        return "other"
    }
}

func nextObservationTick(nanoseconds: UInt64 = 50_000_000) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: nanoseconds))) {
            continuation.resume()
        }
    }
}

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

/// Nearest-rank percentile (rank = ceil(p * n), one-indexed).
func nearestRankPercentile(_ values: [Double], percentile: Double) -> Double? {
    guard !values.isEmpty, percentile > 0, percentile <= 1 else { return nil }
    let sorted = values.sorted()
    let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
    return sorted[rank - 1]
}
