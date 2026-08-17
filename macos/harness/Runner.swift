import AppKit
import Darwin
import Foundation

private let canonicalBenchesRepositoryIdentifier = "github.com/gyldlab/keld-benches"
private let canonicalBenchesRemoteURL = "https://github.com/gyldlab/keld-benches.git"
private let canonicalKeldRepositoryIdentifier = "github.com/gyldlab/keld"
private let canonicalKeldRemoteURL = "https://github.com/gyldlab/keld.git"
private let canonicalRemoteProbeDirectory = URL(fileURLWithPath: "/var/empty", isDirectory: true)
private let requiredTauriSourcePaths = [
    "build.sh",
    "package.json",
    "src/index.html",
    "src-tauri/Cargo.toml",
    "src-tauri/build.rs",
    "src-tauri/capabilities/default.json",
    "src-tauri/icons/icon.icns",
    "src-tauri/src/lib.rs",
    "src-tauri/src/main.rs",
    "src-tauri/tauri.conf.json",
]

private func loadedExecutableURL() throws -> URL {
    var buffer = [CChar](repeating: 0, count: 4_096)
    let byteCount = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
    guard byteCount > 0 else {
        throw HarnessError.io(
            "could not resolve the kernel-reported harness executable; rerun on a supported macOS host"
        )
    }
    return URL(fileURLWithPath: String(cString: buffer))
        .standardizedFileURL
        .resolvingSymlinksInPath()
}

struct AppSpec {
    let label: String
    let bundleURL: URL
    let bundleFileIdentity: FileIdentity
    var argumentTemplates: [String]
    var buildCommand: String?
    var startupTraceEnvironmentVariable: String?
}

private struct StartupTraceOutput {
    let directoryURL: URL
    let fileURL: URL
    let environmentVariable: String
    let token: String

    static func create(environmentVariable: String, token: String) throws -> Self {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("keld-startup-trace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard Darwin.chmod(directoryURL.path, 0o700) == 0 else {
            throw HarnessError.io("could not make the startup-trace directory private")
        }
        let fileURL = directoryURL.appendingPathComponent("trace-v1.txt")
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw HarnessError.measurement("startup trace path unexpectedly already exists")
        }
        return Self(
            directoryURL: directoryURL,
            fileURL: fileURL,
            environmentVariable: environmentVariable,
            token: token
        )
    }

    func remove() {
        do {
            try FileManager.default.removeItem(at: directoryURL)
        } catch {
            writeDiagnostic("startup-trace temporary cleanup failed")
        }
    }

    func readEvidence() throws -> StartupTraceEvidence {
        var information = stat()
        guard Darwin.lstat(fileURL.path, &information) == 0 else {
            throw HarnessError.measurement("startup trace was not written by the traced fixture")
        }
        guard information.st_mode & S_IFMT == S_IFREG,
              information.st_size > 0,
              information.st_size <= 4_096 else {
            throw HarnessError.measurement("startup trace has an invalid file type or size")
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try parseStartupTrace(data, expectedToken: token)
    }
}

struct StartupTraceEvidence: Codable, Equatable {
    let wvRunEnteredMilliseconds: Double
    let eventLoopCreatedMilliseconds: Double
    let windowBuiltMilliseconds: Double
    let webviewBuiltMilliseconds: Double
}

private func parseStartupTrace(_ data: Data, expectedToken: String) throws -> StartupTraceEvidence {
    guard let text = String(data: data, encoding: .utf8), text.utf8.count == data.count else {
        throw HarnessError.measurement("startup trace is not UTF-8")
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count == 7, lines.last == "" else {
        throw HarnessError.measurement("startup trace has an invalid record count")
    }
    let requiredKeys = [
        "version",
        "token",
        "wv_run_entered_ns",
        "event_loop_created_ns",
        "window_built_ns",
        "webview_built_ns",
    ]
    var fields: [String: String] = [:]
    for (expectedKey, line) in zip(requiredKeys, lines.dropLast()) {
        guard let separator = line.firstIndex(of: "=") else {
            throw HarnessError.measurement("startup trace has a malformed field")
        }
        let key = String(line[..<separator])
        let value = String(line[line.index(after: separator)...])
        guard key == expectedKey, !value.isEmpty, fields[key] == nil else {
            throw HarnessError.measurement("startup trace has an unknown, empty, or duplicate field")
        }
        fields[key] = value
    }
    guard fields.count == requiredKeys.count,
          fields["version"] == "1",
          fields["token"] == expectedToken else {
        throw HarnessError.measurement("startup trace version or token does not match this arm")
    }
    func nanoseconds(_ key: String) throws -> UInt64 {
        guard let value = fields[key], let parsed = UInt64(value) else {
            throw HarnessError.measurement("startup trace \(key) is not an unsigned integer")
        }
        return parsed
    }
    let wvRunEntered = try nanoseconds("wv_run_entered_ns")
    let eventLoopCreated = try nanoseconds("event_loop_created_ns")
    let windowBuilt = try nanoseconds("window_built_ns")
    let webviewBuilt = try nanoseconds("webview_built_ns")
    guard wvRunEntered == 0,
          eventLoopCreated > wvRunEntered,
          windowBuilt > eventLoopCreated,
          webviewBuilt > windowBuilt else {
        throw HarnessError.measurement("startup trace stages are incomplete or not strictly ordered")
    }
    return StartupTraceEvidence(
        wvRunEnteredMilliseconds: 0,
        eventLoopCreatedMilliseconds: Double(eventLoopCreated) / 1_000_000,
        windowBuiltMilliseconds: Double(windowBuilt) / 1_000_000,
        webviewBuiltMilliseconds: Double(webviewBuilt) / 1_000_000
    )
}

/// Canonical nonce-bound v1 record emitted by the Keld AC1 recorder tests.
private func keldAC1AcceptedStartupTraceRecord(token: String) -> String {
    "version=1\n"
        + "token=\(token)\n"
        + "wv_run_entered_ns=0\n"
        + "event_loop_created_ns=46906000\n"
        + "window_built_ns=95141000\n"
        + "webview_built_ns=149031000\n"
}

/// Writes a fixture record onto the reserved per-arm path and reads it the
/// same way `runOneSample` does after the external beacon is accepted.
private func evaluateStartupTraceAfterAcceptedBeacon(
    record: String,
    expectedToken: String
) throws -> StartupTraceEvidence {
    let output = try StartupTraceOutput.create(
        environmentVariable: "KELD_BENCH_STARTUP_TRACE",
        token: expectedToken
    )
    defer { output.remove() }
    try Data(record.utf8).write(to: output.fileURL, options: .withoutOverwriting)
    return try output.readEvidence()
}

struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

private struct DescriptorSnapshot: Equatable {
    let identity: FileIdentity
    let size: UInt64
    let mode: UInt16
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    init(_ information: stat) {
        identity = FileIdentity(
            device: UInt64(UInt32(bitPattern: information.st_dev)),
            inode: UInt64(information.st_ino)
        )
        size = UInt64(information.st_size)
        mode = information.st_mode
        modificationSeconds = Int64(information.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
        changeSeconds = Int64(information.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(information.st_ctimespec.tv_nsec)
    }
}

private func descriptorSnapshot(_ descriptor: Int32, label: String) throws -> DescriptorSnapshot {
    var information = stat()
    guard Darwin.fstat(descriptor, &information) == 0 else {
        throw HarnessError.io("fstat failed for \(label): \(String(cString: strerror(errno)))")
    }
    return DescriptorSnapshot(information)
}

private func descriptorFileIdentity(at url: URL) throws -> FileIdentity {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw HarnessError.io("open failed for \(url.lastPathComponent): \(String(cString: strerror(errno)))")
    }
    defer { Darwin.close(descriptor) }
    return try descriptorSnapshot(descriptor, label: url.lastPathComponent).identity
}

private func readStableDescriptorData(
    _ descriptor: Int32,
    expectedIdentity: FileIdentity,
    label: String
) throws -> (data: Data, snapshot: DescriptorSnapshot) {
    let before = try descriptorSnapshot(descriptor, label: label)
    guard before.identity == expectedIdentity else {
        throw HarnessError.io("descriptor identity changed before reading \(label)")
    }
    guard before.size <= UInt64(Int.max) else {
        throw HarnessError.io("\(label) is too large to read safely")
    }
    let expectedByteCount = Int(before.size)
    var data = Data()
    data.reserveCapacity(expectedByteCount)
    var offset: off_t = 0
    while data.count < expectedByteCount {
        let requested = min(1_048_576, expectedByteCount - data.count)
        var buffer = [UInt8](repeating: 0, count: requested)
        let count = buffer.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return pread(descriptor, baseAddress, requested, offset)
        }
        guard count > 0 else {
            if count == 0 {
                throw HarnessError.io("unexpected EOF while reading \(label)")
            }
            throw HarnessError.io("pread failed for \(label): \(String(cString: strerror(errno)))")
        }
        data.append(contentsOf: buffer.prefix(count))
        offset += off_t(count)
    }
    let after = try descriptorSnapshot(descriptor, label: label)
    guard after == before else {
        throw HarnessError.io("\(label) changed while being read")
    }
    return (data, after)
}

private func kernelMappedExecutableIdentity(
    pid: Int32,
    executableURL: URL
) throws -> FileIdentity {
    guard let imageHeader = _dyld_get_image_header(0) else {
        throw HarnessError.io("dyld did not expose the main executable image header")
    }
    let pageSize = UInt64(getpagesize())
    guard pageSize > 0, (pageSize & (pageSize - 1)) == 0 else {
        throw HarnessError.io("macOS reported an invalid VM page size")
    }
    let rawAddress = UInt64(UInt(bitPattern: imageHeader))
    let alignedAddress = rawAddress & ~(pageSize - 1)
    let candidateAddresses = rawAddress == alignedAddress
        ? [rawAddress]
        : [rawAddress, alignedAddress]
    var lastError = EINVAL
    for address in candidateAddresses {
        var region = proc_regionwithpathinfo()
        errno = 0
        let byteCount = proc_pidinfo(
            pid,
            PROC_PIDREGIONPATHINFO,
            address,
            &region,
            Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        )
        if byteCount == 0 {
            lastError = errno
            continue
        }
        guard byteCount == Int32(MemoryLayout<proc_regionwithpathinfo>.size) else {
            throw HarnessError.io("proc_pidinfo returned a truncated executable region record")
        }
        let protection = region.prp_prinfo.pri_protection
        if region.prp_prinfo.pri_offset == 0,
           protection & UInt32(VM_PROT_EXECUTE) != 0 {
            let statistics = region.prp_vip.vip_vi.vi_stat
            return FileIdentity(
                device: UInt64(statistics.vst_dev),
                inode: statistics.vst_ino
            )
        }
        throw HarnessError.io(
            "kernel executable mapping at the dyld main-image header was not offset-zero executable"
        )
    }
    if lastError == ESRCH {
        throw HarnessError.io("process exited while reading the loaded executable mapping")
    }
    throw HarnessError.io(
        "proc_pidinfo could not read the loaded executable mapping (errno \(lastError))"
    )
}

private func descriptorIdentityMatchesMappedIdentity(
    descriptorIdentity: FileIdentity,
    mappedIdentity: FileIdentity
) -> Bool {
    descriptorIdentity == mappedIdentity
}

private final class LoadedExecutableBinding: @unchecked Sendable {
    let url: URL
    let identity: FileIdentity
    let mappedIdentity: FileIdentity
    private let descriptor: Int32

    var isBoundToMappedVnode: Bool {
        descriptorIdentityMatchesMappedIdentity(
            descriptorIdentity: identity,
            mappedIdentity: mappedIdentity
        )
    }

    init() throws {
        let resolvedURL = try loadedExecutableURL()
        guard resolvedURL.lastPathComponent == "keld-macos-bench" else {
            throw HarnessError.io("loaded harness executable must use the keld-macos-bench basename")
        }
        let openedDescriptor = Darwin.open(resolvedURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard openedDescriptor >= 0 else {
            throw HarnessError.io(
                "open failed for loaded harness executable: \(String(cString: strerror(errno)))"
            )
        }
        do {
            let snapshot = try descriptorSnapshot(
                openedDescriptor,
                label: resolvedURL.lastPathComponent
            )
            let mappedExecutableIdentity = try kernelMappedExecutableIdentity(
                pid: getpid(),
                executableURL: resolvedURL
            )
            guard descriptorIdentityMatchesMappedIdentity(
                descriptorIdentity: snapshot.identity,
                mappedIdentity: mappedExecutableIdentity
            ) else {
                throw HarnessError.io(
                    "loaded harness descriptor does not match the kernel executable mapping"
                )
            }
            url = resolvedURL
            identity = snapshot.identity
            mappedIdentity = mappedExecutableIdentity
            descriptor = openedDescriptor
        } catch {
            Darwin.close(openedDescriptor)
            throw error
        }
    }

    deinit { Darwin.close(descriptor) }

    func readData() throws -> Data {
        let mappedIdentity = try kernelMappedExecutableIdentity(pid: getpid(), executableURL: url)
        guard mappedIdentity == identity else {
            throw HarnessError.io("kernel executable mapping no longer matches the retained descriptor")
        }
        return try readStableDescriptorData(
            descriptor,
            expectedIdentity: identity,
            label: url.lastPathComponent
        ).data
    }
}

private func fileIdentity(at url: URL) throws -> FileIdentity {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw HarnessError.io("open failed for \(url.lastPathComponent): \(String(cString: strerror(errno)))")
    }
    defer { Darwin.close(descriptor) }
    var information = stat()
    guard Darwin.fstat(descriptor, &information) == 0 else {
        throw HarnessError.io("fstat failed for \(url.lastPathComponent): \(String(cString: strerror(errno)))")
    }
    guard information.st_mode & S_IFMT == S_IFDIR else {
        throw HarnessError.io("expected an app bundle directory at \(url.lastPathComponent)")
    }
    return FileIdentity(
        device: UInt64(UInt32(bitPattern: information.st_dev)),
        inode: UInt64(information.st_ino)
    )
}

struct RunnerOptions {
    var apps: [AppSpec] = []
    var argumentTemplatesByLabel: [String: [String]] = [:]
    var buildCommandsByLabel: [String: String] = [:]
    var startupTraceEnvironmentVariablesByLabel: [String: String] = [:]
    var runsPerApp = 11
    var timeoutSeconds = 30.0
    var cleanupTimeoutSeconds = 5.0
    var stableObservations = 3
    var stableWindowMilliseconds = 500
    var rssToleranceKiB: UInt64 = 1_024
    var htmlURL: URL?
    var outputURL: URL?
    var publish = false
    var selfTest = false
    var showHelp = false
}

enum GitWorkingTreeState: String, Codable, Equatable {
    case clean
    case dirty
    case unavailable
}

struct RepositoryMetadata: Codable, Equatable {
    let identifier: String?
    let commit: String?
    let workingTreeState: GitWorkingTreeState
    let commitAdvertisedAsOriginHead: Bool?
}

private struct GitSnapshot {
    let rootURL: URL?
    let metadata: RepositoryMetadata
}

struct RepositoryTransitionMetadata: Codable {
    let before: RepositoryMetadata
    let after: RepositoryMetadata
}

struct ArtifactHash: Codable, Equatable {
    let repositoryRelativePath: String
    let sha256: String
    let matchesHeadBlob: Bool
}

struct ObservedToolchainMetadata: Codable, Equatable {
    let evidenceKind: String
    let swiftCompilerVersion: String?
    let xcodeVersion: String?
    let macosSdkVersion: String?
    let bunVersion: String?
    let tauriCliVersion: String?
    let rustcVersion: String?
    let cargoVersion: String?
}

struct HostMetadata: Codable, Equatable {
    let operatingSystemVersion: String
    let architecture: String
    let hardwareModel: String
    let processor: String
    let logicalCpuCount: Int
    let physicalMemoryBytes: UInt64
    let lowPowerModeEnabled: Bool
    let thermalState: String
}

struct HostConditionEvidence: Codable, Equatable {
    let lowPowerModeEnabled: Bool
    let thermalState: String

    var isNominalForPublication: Bool {
        !lowPowerModeEnabled && thermalState == "nominal"
    }
}

struct HarnessRebuildEvidence: Codable, Equatable {
    let attempted: Bool
    let rebuiltExecutableSha256: String?
    let byteForByteMatchesRunningExecutable: Bool
    let loadedExecutableBoundToMappedVnode: Bool
    let pathReplacementRejected: Bool
    let immutableHeadBlobTreeVerified: Bool
    let transientLiveSourceSubstitutionRejected: Bool
}

struct HarnessArtifactMetadata: Codable {
    let executableSizeBytes: UInt64
    let executableSha256: String
    let buildInvocationContract: String
    let reproducibleBuild: HarnessRebuildEvidence
    let sourceRepository: RepositoryMetadata
    let sourceFiles: [ArtifactHash]
    let observedToolchain: ObservedToolchainMetadata
}

struct FixtureMetadata: Codable, Equatable {
    let label: String
    let appBundleName: String
    let bundleIdentifier: String?
    let bundleVersion: String?
    let appBundleTreeSha256: String
    let executableBundleRelativePath: String?
    let executableSizeBytes: UInt64?
    let executableSha256: String?
    let sourceRepository: RepositoryMetadata?
    let sourceRepositoryRelativePath: String?
    let embeddedFixtureKind: String?
    let embeddedSourceRepositoryIdentifier: String?
    let embeddedSourceGitCommit: String?
    let embeddedSourceRepositoryRelativePath: String?
    let embeddedSourceCommitAdvertisedAsOriginHead: Bool?
    let embeddedRecipeRepositoryIdentifier: String?
    let embeddedRecipeGitCommit: String?
    let embeddedBuildRecipeIdentifier: String?
    let adapterPatchSha256: String?
    let buildScriptSha256: String?
    let infoPlistTemplateSha256: String?
    let buildCommandSha256: String
    let argumentTemplateSha256: [String]
    let sourceFiles: [ArtifactHash]
    let lockfiles: [ArtifactHash]
    let toolchain: ObservedToolchainMetadata
}

struct ProtocolMetadata: Codable {
    let listener: String
    let htmlFileName: String
    let htmlSha256: String
    let tokenTransports: [String]
    let completionSignal: String
    let launchApi: String
    let coalitionApi: String
}

struct MeasurementConfiguration: Codable {
    let runsPerApp: Int
    let appOrder: String
    let sampleTimeoutSeconds: Double
    let cleanupTimeoutSeconds: Double
    let stableCoalitionObservations: Int
    let stableCoalitionWindowMilliseconds: Int
    let rssToleranceKiB: UInt64
    let observationPollMilliseconds: Int
    let cacheState: String
}

struct CleanupRecord: Codable {
    let gracefulTerminateAccepted: Bool
    let coalitionHardKillInvoked: Bool
    let applicationTerminated: Bool
    let coalitionDrained: Bool?
    let error: String?
}

private func hasUnresolvedLaunchOwnership(_ cleanupRecords: [CleanupRecord?]) -> Bool {
    cleanupRecords.contains { $0?.error == "process_identity_unavailable" }
}

private struct PublicEvidenceContext {
    private let salt: String
    let t0MonotonicNanoseconds: UInt64

    init(t0MonotonicNanoseconds: UInt64, salt: String = UUID().uuidString) {
        self.salt = salt
        self.t0MonotonicNanoseconds = t0MonotonicNanoseconds
    }

    func processPseudonym(_ pid: Int32) -> String {
        pseudonym(kind: "process", value: String(pid))
    }

    func coalitionPseudonym(_ coalitionId: UInt64) -> String {
        pseudonym(kind: "coalition", value: String(coalitionId))
    }

    func offsetMilliseconds(for monotonicNanoseconds: UInt64) -> Double {
        if monotonicNanoseconds >= t0MonotonicNanoseconds {
            return Double(monotonicNanoseconds - t0MonotonicNanoseconds) / 1_000_000
        }
        return -Double(t0MonotonicNanoseconds - monotonicNanoseconds) / 1_000_000
    }

    private func pseudonym(kind: String, value: String) -> String {
        let digest = sha256Hex(Data("keld-public-evidence-v1\0\(salt)\0\(kind)\0\(value)".utf8))
        return "\(kind)-\(digest.prefix(24))"
    }
}

struct StableProcessEvidence: Codable, Equatable {
    let processPseudonym: String
    let parentProcessPseudonym: String?
    let commandSha256: String?

    fileprivate init(_ identity: StableProcessIdentity, context: PublicEvidenceContext) {
        processPseudonym = context.processPseudonym(identity.pid)
        parentProcessPseudonym = identity.parentPid > 0
            ? context.processPseudonym(identity.parentPid)
            : nil
        commandSha256 = identity.commandSha256
    }
}

struct BeaconEvidence: Codable {
    let receivedOffsetMilliseconds: Double
    let clientNowMilliseconds: Double?
    let scriptStartMilliseconds: Double?
    let firstRafMilliseconds: Double?
    let secondRafMilliseconds: Double?
    let documentVisibilityState: String?
    let documentHadFocus: Bool?

    fileprivate init(_ receipt: BeaconReceipt, context: PublicEvidenceContext) {
        receivedOffsetMilliseconds = context.offsetMilliseconds(
            for: receipt.receivedMonotonicNanoseconds
        )
        clientNowMilliseconds = receipt.clientNowMilliseconds
        scriptStartMilliseconds = receipt.scriptStartMilliseconds
        firstRafMilliseconds = receipt.firstRafMilliseconds
        secondRafMilliseconds = receipt.secondRafMilliseconds
        documentVisibilityState = receipt.documentVisibilityState
        documentHadFocus = receipt.documentHadFocus
    }
}

struct ProcessMeasurementEvidence: Codable, Equatable {
    let processPseudonym: String
    let parentProcessPseudonym: String?
    let rssKiB: UInt64
    let classification: String
    let commandSha256: String

    fileprivate init(_ process: ProcessMeasurement, context: PublicEvidenceContext) {
        processPseudonym = context.processPseudonym(process.pid)
        parentProcessPseudonym = process.parentPid > 0
            ? context.processPseudonym(process.parentPid)
            : nil
        rssKiB = process.rssKiB
        classification = process.classification
        commandSha256 = process.commandSha256
    }
}

struct CoalitionIdentityEvidence: Codable, Equatable {
    let coalitionPseudonym: String
    let bundleIdentifier: String?
    let activeProcessCount: Int?

    fileprivate init(_ identity: CoalitionIdentity, context: PublicEvidenceContext) {
        coalitionPseudonym = context.coalitionPseudonym(identity.id)
        bundleIdentifier = identity.bundleIdentifier
        activeProcessCount = identity.activeCount
    }
}

struct CoalitionEvidence: Codable, Equatable {
    let identity: CoalitionIdentityEvidence
    let membershipLifecycleStableDuringAcceptedObservation: Bool
    let processes: [ProcessMeasurementEvidence]
    let rssByClassificationKiB: [String: UInt64]
    let totalRssKiB: UInt64
    let observedOffsetMilliseconds: Double

    fileprivate init(_ snapshot: CoalitionSnapshot, context: PublicEvidenceContext) {
        identity = CoalitionIdentityEvidence(snapshot.identity, context: context)
        membershipLifecycleStableDuringAcceptedObservation = true
        processes = snapshot.processes.map {
            ProcessMeasurementEvidence($0, context: context)
        }
        rssByClassificationKiB = snapshot.rssByClassificationKiB
        totalRssKiB = snapshot.totalRssKiB
        observedOffsetMilliseconds = context.offsetMilliseconds(
            for: snapshot.observedMonotonicNanoseconds
        )
    }
}

struct ServerEventEvidence: Codable {
    let offsetMilliseconds: Double
    let kind: String
    let status: Int
    let accepted: Bool
    let reason: String

    fileprivate init(_ event: ServerEvent, context: PublicEvidenceContext) {
        offsetMilliseconds = context.offsetMilliseconds(for: event.monotonicNanoseconds)
        kind = event.kind
        status = event.status
        accepted = event.accepted
        reason = event.reason
    }
}

struct SampleRecord: Codable {
    let globalOrdinal: Int
    let round: Int
    let appOrdinal: Int
    let label: String
    let status: String
    let error: String?
    let launchedProcessIdentity: StableProcessEvidence?
    let launchServicesASNResolved: Bool?
    let launchServicesOriginalPidPresent: Bool?
    let originalPidMatchesReturnedPidCoalition: Bool?
    let launchCallbackOffsetMilliseconds: Double?
    let applicationWasActiveAtLaunchCallback: Bool?
    let applicationWasActiveAtBeacon: Bool?
    let foreground: ForegroundEvidence
    let hostConditionBeforeLaunch: HostConditionEvidence
    let hostConditionAfterCleanup: HostConditionEvidence
    let beacon: BeaconEvidence?
    let doubleRafPaintOpportunityProxyMilliseconds: Double?
    let startupTrace: StartupTraceEvidence?
    let stableCoalitionObservations: Int?
    let coalition: CoalitionEvidence?
    let serverEvents: [ServerEventEvidence]
    let cleanup: CleanupRecord?
}

struct ForegroundEvidence: Codable {
    let observerInstalledBeforeLaunch: Bool
    let anchorGenerationCaptured: Bool
    let targetGenerationCaptured: Bool
    let targetActivatedBeforeBeacon: Bool
    let transitionUninterruptedBeforeBeacon: Bool
    let exactAnchorRestoredAfterCleanup: Bool
    let reasonCode: ForegroundFailureReason?

    var isCompleteForPublication: Bool {
        observerInstalledBeforeLaunch
            && anchorGenerationCaptured
            && targetGenerationCaptured
            && targetActivatedBeforeBeacon
            && transitionUninterruptedBeforeBeacon
            && exactAnchorRestoredAfterCleanup
            && reasonCode == nil
    }

    static func captureFailure(_ reason: ForegroundFailureReason) -> ForegroundEvidence {
        ForegroundEvidence(
            observerInstalledBeforeLaunch: true,
            anchorGenerationCaptured: false,
            targetGenerationCaptured: false,
            targetActivatedBeforeBeacon: false,
            transitionUninterruptedBeforeBeacon: false,
            exactAnchorRestoredAfterCleanup: false,
            reasonCode: reason
        )
    }

    static let notAttempted = ForegroundEvidence(
        observerInstalledBeforeLaunch: false,
        anchorGenerationCaptured: false,
        targetGenerationCaptured: false,
        targetActivatedBeforeBeacon: false,
        transitionUninterruptedBeforeBeacon: false,
        exactAnchorRestoredAfterCleanup: false,
        reasonCode: nil
    )
}

struct ForegroundSessionEvidence: Codable {
    let observerInstalledOnceBeforeArms: Bool
    let observerRemainedInstalledThroughArms: Bool
    let immutableAnchorUsedForEveryStartedSample: Bool
    let committedCursorAdvancedOnlyAfterExactRestoration: Bool
    let allSampleLeasesReleased: Bool
    let tailSealedAtExactAnchor: Bool
    let atLeastOneSampleStarted: Bool
    let exactRestorationCommittedForEveryStartedSample: Bool
    let everyStartedSampleFinished: Bool
    let startedSampleCount: Int
    let exactRestorationCount: Int
    let finishedSampleCount: Int

    init(
        observerInstalledOnceBeforeArms: Bool,
        observerRemainedInstalledThroughArms: Bool,
        immutableAnchorUsedForEveryStartedSample: Bool,
        committedCursorAdvancedOnlyAfterExactRestoration: Bool,
        allSampleLeasesReleased: Bool,
        tailSealedAtExactAnchor: Bool,
        samplesStarted: Int,
        exactRestorationCommitCount: Int,
        finishedSampleCount: Int
    ) {
        self.observerInstalledOnceBeforeArms = observerInstalledOnceBeforeArms
        self.observerRemainedInstalledThroughArms = observerRemainedInstalledThroughArms
        self.immutableAnchorUsedForEveryStartedSample = immutableAnchorUsedForEveryStartedSample
        self.committedCursorAdvancedOnlyAfterExactRestoration =
            committedCursorAdvancedOnlyAfterExactRestoration
        self.allSampleLeasesReleased = allSampleLeasesReleased
        self.tailSealedAtExactAnchor = tailSealedAtExactAnchor
        atLeastOneSampleStarted = samplesStarted > 0
        exactRestorationCommittedForEveryStartedSample =
            exactRestorationCommitCount == samplesStarted
        everyStartedSampleFinished = finishedSampleCount == samplesStarted
        startedSampleCount = samplesStarted
        exactRestorationCount = exactRestorationCommitCount
        self.finishedSampleCount = finishedSampleCount
    }

    func isCompleteForPublication(recordedSampleCount: Int) -> Bool {
        recordedSampleCount > 0
            && observerInstalledOnceBeforeArms
            && observerRemainedInstalledThroughArms
            && immutableAnchorUsedForEveryStartedSample
            && committedCursorAdvancedOnlyAfterExactRestoration
            && allSampleLeasesReleased
            && tailSealedAtExactAnchor
            && atLeastOneSampleStarted
            && exactRestorationCommittedForEveryStartedSample
            && everyStartedSampleFinished
            && startedSampleCount == recordedSampleCount
            && exactRestorationCount == recordedSampleCount
            && finishedSampleCount == recordedSampleCount
    }
}

struct PublicationReason: Codable, Equatable {
    let code: String
    let label: String?
}

struct PublicationMetadata: Codable {
    let policyVersion: Int
    let requested: Bool
    let eligible: Bool
    let reasons: [PublicationReason]
}

private struct BenchmarkOutcome {
    let measurementSucceeded: Bool
    let publicationEligible: Bool
}

struct MetricSummary: Codable {
    let sampleCount: Int
    let median: Double?
    let p90NearestRank: Double?
    let minimum: Double?
    let maximum: Double?
}

struct AppSummary: Codable {
    let label: String
    let successfulSamples: Int
    let failedSamples: Int
    let doubleRafPaintOpportunityProxyMilliseconds: MetricSummary
    let totalCoalitionRssKiB: MetricSummary
}

struct BenchmarkDocument: Codable {
    let schemaVersion: Int
    let harnessVersion: String
    let startedAtUtc: String
    let finishedAtUtc: String
    let repository: RepositoryTransitionMetadata
    let harnessArtifact: HarnessArtifactMetadata
    let hostBefore: HostMetadata
    let hostAfter: HostMetadata
    let fixtures: [FixtureMetadata]
    let protocolMetadata: ProtocolMetadata
    let configuration: MeasurementConfiguration
    let foregroundSession: ForegroundSessionEvidence
    let samples: [SampleRecord]
    let summaries: [AppSummary]
    let abortedReason: String?
    let publication: PublicationMetadata
}

private struct LaunchOutcome {
    let application: NSRunningApplication
    let launchedPid: Int32
    let kernelOwnership: KernelLaunchOwnership?
    let t0Nanoseconds: UInt64
    let callbackNanoseconds: UInt64
    let wasActiveAtCallback: Bool
    let callbackError: String?
}

private struct ForegroundActivationEvent: Sendable {
    let monotonicNanoseconds: UInt64
    let generation: ForegroundProcessGeneration?
}

private struct ForegroundRestorationRecorderSnapshot {
    let startIndex: Int
    let revision: UInt64
    let slotCount: Int
    let nextIndex: Int
    let values: [ForegroundActivationEvent]
    let hasIncompleteObservation: Bool
}

private struct ForegroundRestorationDecision {
    private(set) var hasCompletedActivationIntent = false
    private(set) var latestCompletedActivationIntent: ForegroundProcessGeneration?

    mutating func drain(_ events: [ForegroundActivationEvent]) {
        for event in events {
            hasCompletedActivationIntent = true
            latestCompletedActivationIntent = event.generation
        }
    }

    func canAccept(
        anchor: ForegroundProcessGeneration,
        frontmost: ForegroundProcessGeneration?,
        hasIncompleteObservation: Bool,
        recorderSnapshotIsCurrent: Bool
    ) -> Bool {
        hasCompletedActivationIntent
            && latestCompletedActivationIntent == anchor
            && !hasIncompleteObservation
            && frontmost == anchor
            && recorderSnapshotIsCurrent
    }
}

private func foregroundTailCanSeal(
    anchor: ForegroundProcessGeneration,
    events: [ForegroundActivationEvent],
    hasIncompleteObservation: Bool,
    anchorStatus: ForegroundAnchorGenerationStatus,
    frontmost: ForegroundProcessGeneration?
) -> Bool {
    !hasIncompleteObservation
        && anchorStatus == .sameGeneration
        && frontmost == anchor
        && events.allSatisfy { $0.generation == anchor }
}

private struct ForegroundObservationSeed: Sendable {
    let id: UUID
    let monotonicNanoseconds: UInt64
}

#if FOREGROUND_STATE_SELF_TEST
private final class ForegroundObservationAdmissionBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var admissionWorkStarted = false
    private var admissionWorkObservedRecorderLockHeld = false
    private var sealWillContend = false

    func supplyObservationSeedWhileRecorderLockShouldBeOwned(
        recorderLockHeld: Bool
    ) -> ForegroundObservationSeed {
        condition.lock()
        admissionWorkStarted = true
        admissionWorkObservedRecorderLockHeld = recorderLockHeld
        condition.broadcast()
        let deadline = Date().addingTimeInterval(2)
        while !sealWillContend, condition.wait(until: deadline) {}
        condition.unlock()
        return ForegroundObservationSeed(
            id: UUID(),
            monotonicNanoseconds: monotonicNowNanoseconds()
        )
    }

    func awaitAdmissionWorkStarting() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while !admissionWorkStarted {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func observedRecorderLockHeldDuringAdmissionWork() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return admissionWorkObservedRecorderLockHeld
    }

    func announceSealContention() {
        condition.lock()
        sealWillContend = true
        condition.broadcast()
        condition.unlock()
    }
}
#endif

private final class ForegroundActivationRecorder: @unchecked Sendable {
    struct ObservationHandle {
        let id: UUID
        let monotonicNanoseconds: UInt64
    }

    private struct ObservationSlot {
        let id: UUID
        let monotonicNanoseconds: UInt64
        var completed = false
        var generation: ForegroundProcessGeneration?
    }

    private struct Waiter {
        let observedRevision: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private let timeoutQueue = DispatchQueue(label: "com.keld.benches.harness.foreground-timeout")
    private var slots: [ObservationSlot] = []
    private var slotIndexesById: [UUID: Int] = [:]
    private var revision: UInt64 = 0
    private var waiters: [UUID: Waiter] = [:]
    private var closed = false
#if FOREGROUND_STATE_SELF_TEST
    private let testAdmissionBarrier: ForegroundObservationAdmissionBarrier?
    private let testObservationSeedProvider:
        (@Sendable (Bool) -> ForegroundObservationSeed)?
    private var testAdmissionLockHeld = false

    init(
        testAdmissionBarrier: ForegroundObservationAdmissionBarrier? = nil,
        testObservationSeedProvider:
            (@Sendable (Bool) -> ForegroundObservationSeed)? = nil
    ) {
        self.testAdmissionBarrier = testAdmissionBarrier
        self.testObservationSeedProvider = testObservationSeedProvider
    }
#else
    init() {}
#endif

    func beginObservation() -> ObservationHandle? {
        lock.lock()
#if FOREGROUND_STATE_SELF_TEST
        testAdmissionLockHeld = true
#endif
        guard !closed else {
#if FOREGROUND_STATE_SELF_TEST
            testAdmissionLockHeld = false
#endif
            lock.unlock()
            return nil
        }
        let seed = makeObservationSeed()
        let observationId = seed.id
        let now = seed.monotonicNanoseconds
        let monotonicNanoseconds: UInt64
        if let last = slots.last?.monotonicNanoseconds, now <= last {
            monotonicNanoseconds = last &+ 1
        } else {
            monotonicNanoseconds = now
        }
        let handle = ObservationHandle(
            id: observationId,
            monotonicNanoseconds: monotonicNanoseconds
        )
        slotIndexesById[handle.id] = slots.count
        slots.append(ObservationSlot(
            id: handle.id,
            monotonicNanoseconds: handle.monotonicNanoseconds
        ))
        revision &+= 1
        let currentRevision = revision
        let ready = waiters.filter { $0.value.observedRevision < currentRevision }
        for (id, _) in ready { waiters.removeValue(forKey: id) }
#if FOREGROUND_STATE_SELF_TEST
        testAdmissionLockHeld = false
#endif
        lock.unlock()
        for (_, waiter) in ready { waiter.continuation.resume(returning: true) }
        return handle
    }

    private func makeObservationSeed() -> ForegroundObservationSeed {
#if FOREGROUND_STATE_SELF_TEST
        if let testObservationSeedProvider {
            return testObservationSeedProvider(testAdmissionLockHeld)
        }
#endif
        return ForegroundObservationSeed(
            id: UUID(),
            monotonicNanoseconds: monotonicNowNanoseconds()
        )
    }

    func completeObservation(
        _ observationId: UUID,
        generation: ForegroundProcessGeneration?
    ) {
        lock.lock()
        guard let slotIndex = slotIndexesById[observationId],
              !slots[slotIndex].completed else {
            lock.unlock()
            return
        }
        slots[slotIndex].completed = true
        slots[slotIndex].generation = generation
        revision &+= 1
        let currentRevision = revision
        let ready = waiters.filter { $0.value.observedRevision < currentRevision }
        for (id, _) in ready { waiters.removeValue(forKey: id) }
        lock.unlock()
        for (_, waiter) in ready { waiter.continuation.resume(returning: true) }
    }

    func events(after index: Int, through cutoffNanoseconds: UInt64) -> (
        values: [ForegroundActivationEvent],
        nextIndex: Int,
        hasIncompleteObservationAtOrBeforeCutoff: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard index <= slots.count else {
            return ([], index, true)
        }
        var nextIndex = index
        var values: [ForegroundActivationEvent] = []
        var hasIncompleteObservationAtOrBeforeCutoff = false
        while nextIndex < slots.count,
              slots[nextIndex].monotonicNanoseconds <= cutoffNanoseconds {
            let slot = slots[nextIndex]
            guard slot.completed else {
                hasIncompleteObservationAtOrBeforeCutoff = true
                break
            }
            values.append(ForegroundActivationEvent(
                monotonicNanoseconds: slot.monotonicNanoseconds,
                generation: slot.generation
            ))
            nextIndex += 1
        }
        return (
            values,
            nextIndex,
            hasIncompleteObservationAtOrBeforeCutoff
        )
    }

    func restorationSnapshot(after index: Int) -> ForegroundRestorationRecorderSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard index <= slots.count else {
            return ForegroundRestorationRecorderSnapshot(
                startIndex: index,
                revision: revision,
                slotCount: slots.count,
                nextIndex: index,
                values: [],
                hasIncompleteObservation: true
            )
        }

        var nextIndex = index
        var values: [ForegroundActivationEvent] = []
        while nextIndex < slots.count {
            let slot = slots[nextIndex]
            guard slot.completed else { break }
            values.append(ForegroundActivationEvent(
                monotonicNanoseconds: slot.monotonicNanoseconds,
                generation: slot.generation
            ))
            nextIndex += 1
        }
        return ForegroundRestorationRecorderSnapshot(
            startIndex: index,
            revision: revision,
            slotCount: slots.count,
            nextIndex: nextIndex,
            values: values,
            hasIncompleteObservation: nextIndex < slots.count
        )
    }

    func restorationSnapshotIsCurrent(
        _ snapshot: ForegroundRestorationRecorderSnapshot
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return restorationSnapshotIsCurrentLocked(snapshot)
    }

    @MainActor
    func withCurrentSnapshot(
        _ snapshot: ForegroundRestorationRecorderSnapshot,
        acceptance: () -> Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard restorationSnapshotIsCurrentLocked(snapshot) else { return false }
        return acceptance()
    }

    @MainActor
    func sealCurrentSnapshot(
        _ snapshot: ForegroundRestorationRecorderSnapshot,
        acceptance: () -> Bool
    ) -> Bool {
#if FOREGROUND_STATE_SELF_TEST
        testAdmissionBarrier?.announceSealContention()
#endif
        lock.lock()
        defer { lock.unlock() }
        guard !closed,
              restorationSnapshotIsCurrentLocked(snapshot),
              acceptance() else {
            return false
        }
        closed = true
        return true
    }

    func stopAcceptingObservations() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    private func restorationSnapshotIsCurrentLocked(
        _ snapshot: ForegroundRestorationRecorderSnapshot
    ) -> Bool {
        guard revision == snapshot.revision,
              slots.count == snapshot.slotCount,
              snapshot.startIndex <= slots.count else {
            return false
        }
        var completedPrefixEnd = snapshot.startIndex
        while completedPrefixEnd < slots.count,
              slots[completedPrefixEnd].completed {
            completedPrefixEnd += 1
        }
        return completedPrefixEnd == snapshot.nextIndex
            && (completedPrefixEnd < slots.count) == snapshot.hasIncompleteObservation
    }

    func waitForEvent(after observedRevision: UInt64, deadlineNanoseconds: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiterId = UUID()
            lock.lock()
            if revision > observedRevision {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            let now = monotonicNowNanoseconds()
            if now >= deadlineNanoseconds {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            waiters[waiterId] = Waiter(
                observedRevision: observedRevision,
                continuation: continuation
            )
            lock.unlock()
            timeoutQueue.asyncAfter(
                deadline: .now() + .nanoseconds(Int(clamping: deadlineNanoseconds - now))
            ) { [weak self] in
                self?.timeout(waiterId)
            }
        }
    }

    func cancelWaiters() {
        lock.lock()
        let pending = waiters.values
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.continuation.resume(returning: false) }
    }

    private func timeout(_ waiterId: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: waiterId)
        lock.unlock()
        waiter?.continuation.resume(returning: false)
    }
}

private func foregroundGeneration(
    for application: NSRunningApplication
) throws -> ForegroundProcessGeneration? {
    let pid = application.processIdentifier
    guard let identity = try kernelProcessUniqueIdentity(for: pid) else { return nil }
    return ForegroundProcessGeneration(
        pid: pid,
        uniqueId: identity.uniqueId,
        pidVersion: identity.pidVersion
    )
}

@MainActor
private final class ForegroundSessionMonitor {
    private let workspace: NSWorkspace
    private let notificationCenter: NotificationCenter
    private let observation: NSObjectProtocol
    private let recorder: ForegroundActivationRecorder
    private let continuityToken = UUID()
    private var cursorState: ForegroundSessionCursorState
    private var stopped = false
    private var armsFinished = false
    private var immutableAnchorUsedForEveryStartedSample = true
    private var committedCursorAdvancedOnlyAfterExactRestoration = true
    private var samplesStarted = 0
    private var exactRestorationCommitCount = 0
    private var finishedSampleCount = 0
    private var lastRestorationCommittedLeaseId: UInt64?

    private init(
        workspace: NSWorkspace,
        notificationCenter: NotificationCenter,
        observation: NSObjectProtocol,
        recorder: ForegroundActivationRecorder,
        committedCursor: Int,
        anchor: ForegroundProcessGeneration
    ) {
        self.workspace = workspace
        self.notificationCenter = notificationCenter
        self.observation = observation
        self.recorder = recorder
        cursorState = ForegroundSessionCursorState(
            anchor: anchor,
            committedCursor: committedCursor
        )
    }

    static func capture() throws -> ForegroundSessionMonitor {
        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter
        let recorder = ForegroundActivationRecorder()
        let observation = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let observation = recorder.beginObservation() else { return }
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else {
                recorder.completeObservation(observation.id, generation: nil)
                return
            }
            do {
                recorder.completeObservation(
                    observation.id,
                    generation: try foregroundGeneration(for: application)
                )
            } catch {
                writeDiagnostic("foreground activation generation capture failed: \(error)")
                recorder.completeObservation(observation.id, generation: nil)
            }
        }
        do {
            let initialSnapshot = recorder.restorationSnapshot(after: 0)
            guard !initialSnapshot.hasIncompleteObservation else {
                throw HarnessError.foregroundInterference(.activationGenerationUnavailable)
            }
            guard let anchorApplication = workspace.frontmostApplication else {
                throw HarnessError.foregroundInterference(.anchorUnavailable)
            }
            guard let captured = try foregroundGeneration(for: anchorApplication) else {
                throw HarnessError.foregroundInterference(.anchorGenerationUnavailable)
            }
            for event in initialSnapshot.values where event.generation == nil {
                _ = event
                throw HarnessError.foregroundInterference(.activationGenerationUnavailable)
            }
            if let latestIntent = initialSnapshot.values.last?.generation,
               latestIntent != captured {
                throw HarnessError.foregroundInterference(.anchorChangedBeforeLaunch)
            }
            let snapshotAccepted = recorder.withCurrentSnapshot(
                initialSnapshot,
                acceptance: { true }
            )
            guard snapshotAccepted else {
                throw HarnessError.foregroundInterference(.activationGenerationUnavailable)
            }
            return ForegroundSessionMonitor(
                workspace: workspace,
                notificationCenter: notificationCenter,
                observation: observation,
                recorder: recorder,
                committedCursor: initialSnapshot.nextIndex,
                anchor: captured
            )
        } catch {
            notificationCenter.removeObserver(observation)
            recorder.cancelWaiters()
            if let harnessError = error as? HarnessError { throw harnessError }
            writeDiagnostic("foreground session anchor capture failed: \(error)")
            throw HarnessError.foregroundInterference(.anchorGenerationUnavailable)
        }
    }

    func beginSample() throws -> ForegroundSampleMonitor {
        guard !stopped, !armsFinished,
              let lease = cursorState.beginSample() else {
            throw HarnessError.measurement(
                "foreground session already owns an active sample; finish it before starting another"
            )
        }
        let sample = ForegroundSampleMonitor(
            session: self,
            workspace: workspace,
            recorder: recorder,
            lease: lease,
            anchor: cursorState.anchor,
            continuityToken: continuityToken
        )
        immutableAnchorUsedForEveryStartedSample = immutableAnchorUsedForEveryStartedSample
            && sample.anchor == cursorState.anchor
        samplesStarted += 1
        return sample
    }

    func owns(
        _ lease: ForegroundSampleLease,
        anchor: ForegroundProcessGeneration,
        continuityToken: UUID
    ) -> Bool {
        !stopped
            && self.continuityToken == continuityToken
            && cursorState.anchor == anchor
            && cursorState.owns(lease)
    }

    func commitExactRestoration(
        _ lease: ForegroundSampleLease,
        cursor: Int,
        anchor: ForegroundProcessGeneration,
        continuityToken: UUID
    ) -> Bool {
        guard owns(lease, anchor: anchor, continuityToken: continuityToken),
              lastRestorationCommittedLeaseId != lease.id,
              cursorState.commit(lease, cursor: cursor) else {
            committedCursorAdvancedOnlyAfterExactRestoration = false
            return false
        }
        lastRestorationCommittedLeaseId = lease.id
        exactRestorationCommitCount += 1
        return true
    }

    func endSample(_ lease: ForegroundSampleLease) -> Bool {
        guard cursorState.end(lease) else { return false }
        finishedSampleCount += 1
        return true
    }

    func finishArms() -> ForegroundSessionEvidence {
        armsFinished = true
        let observerRemainedInstalledThroughArms = !stopped
        let tailSnapshot = recorder.restorationSnapshot(after: cursorState.committedCursor)
        let tailSealedAtExactAnchor = recorder.sealCurrentSnapshot(
            tailSnapshot,
            acceptance: {
                guard !stopped,
                      cursorState.activeLease == nil else {
                    return false
                }

                let liveAnchorStatus: ForegroundAnchorGenerationStatus
                let frontmost: ForegroundProcessGeneration?
                do {
                    guard let liveIdentity = try kernelProcessUniqueIdentity(
                        for: cursorState.anchor.pid
                    ) else {
                        return false
                    }
                    liveAnchorStatus = liveIdentity.uniqueId == cursorState.anchor.uniqueId
                        && liveIdentity.pidVersion == cursorState.anchor.pidVersion
                        ? .sameGeneration
                        : .reused
                    frontmost = try workspace.frontmostApplication.flatMap(foregroundGeneration)
                } catch {
                    writeDiagnostic("foreground end-of-arms tail seal failed: \(error)")
                    return false
                }

                guard foregroundTailCanSeal(
                    anchor: cursorState.anchor,
                    events: tailSnapshot.values,
                    hasIncompleteObservation: tailSnapshot.hasIncompleteObservation,
                    anchorStatus: liveAnchorStatus,
                    frontmost: frontmost
                ) else {
                    return false
                }
                return cursorState.sealTail(cursor: tailSnapshot.nextIndex)
            }
        )
        if !tailSealedAtExactAnchor {
            recorder.stopAcceptingObservations()
        }
        return ForegroundSessionEvidence(
            observerInstalledOnceBeforeArms: true,
            observerRemainedInstalledThroughArms: observerRemainedInstalledThroughArms,
            immutableAnchorUsedForEveryStartedSample: immutableAnchorUsedForEveryStartedSample,
            committedCursorAdvancedOnlyAfterExactRestoration: committedCursorAdvancedOnlyAfterExactRestoration,
            allSampleLeasesReleased: cursorState.activeLease == nil,
            tailSealedAtExactAnchor: tailSealedAtExactAnchor,
            samplesStarted: samplesStarted,
            exactRestorationCommitCount: exactRestorationCommitCount,
            finishedSampleCount: finishedSampleCount
        )
    }

    func observerIsContinuous(_ token: UUID) -> Bool {
        !stopped && continuityToken == token
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        recorder.stopAcceptingObservations()
        notificationCenter.removeObserver(observation)
        recorder.cancelWaiters()
    }
}

@MainActor
private final class ForegroundSampleMonitor {
    fileprivate let anchor: ForegroundProcessGeneration
    private let session: ForegroundSessionMonitor
    private let workspace: NSWorkspace
    private let recorder: ForegroundActivationRecorder
    private let lease: ForegroundSampleLease
    private let continuityToken: UUID
    private var eventCursor: Int
    private var state: ForegroundTransitionState
    private var restorationCommitted = false
    private var finished = false

    init(
        session: ForegroundSessionMonitor,
        workspace: NSWorkspace,
        recorder: ForegroundActivationRecorder,
        lease: ForegroundSampleLease,
        anchor: ForegroundProcessGeneration,
        continuityToken: UUID
    ) {
        self.session = session
        self.workspace = workspace
        self.recorder = recorder
        self.lease = lease
        self.anchor = anchor
        self.continuityToken = continuityToken
        eventCursor = lease.startCursor
        state = ForegroundTransitionState(anchor: anchor)
    }

    func prepareForLaunch() throws {
        let recorderSnapshot = recorder.restorationSnapshot(after: eventCursor)
        guard !recorderSnapshot.hasIncompleteObservation else {
            state.activationGenerationWasUnavailable()
            try throwIfFailed()
            return
        }
        for event in recorderSnapshot.values {
            state.observeBetweenSampleActivation(event.generation)
        }
        try throwIfFailed()

        let generation: ForegroundProcessGeneration?
        do {
            generation = try workspace.frontmostApplication.flatMap(foregroundGeneration)
        } catch {
            writeDiagnostic("foreground pre-launch generation check failed: \(error)")
            state.reject(.anchorGenerationUnavailable)
            throw HarnessError.foregroundInterference(.anchorGenerationUnavailable)
        }
        let accepted = recorder.withCurrentSnapshot(recorderSnapshot, acceptance: {
            guard session.owns(
                lease,
                anchor: anchor,
                continuityToken: continuityToken
            ) else {
                return false
            }
            state.prepareForLaunch(current: generation)
            guard state.failureReason == nil else { return false }
            eventCursor = recorderSnapshot.nextIndex
            return true
        })
        guard accepted else {
            if state.failureReason == nil { state.activationGenerationWasUnavailable() }
            try throwIfFailed()
            return
        }
        try throwIfFailed()
    }

    func bindTarget(_ ownership: KernelLaunchOwnership?) throws {
        let generation = ownership.map {
            ForegroundProcessGeneration(
                pid: $0.pid,
                uniqueId: $0.uniqueId,
                pidVersion: $0.pidVersion
            )
        }
        state.bindTarget(generation)
        inspectPreBeaconEvents(through: monotonicNowNanoseconds())
        try throwIfFailed()
    }

    func acceptBeacon(_ beacon: BeaconReceipt, targetReportsActive: Bool) throws {
        inspectPreBeaconEvents(through: beacon.receivedMonotonicNanoseconds)
        state.acceptBeacon(targetReportsActive: targetReportsActive)
        try throwIfFailed()
    }

    func inspectPreBeaconEvents(through cutoffNanoseconds: UInt64) {
        let captured = recorder.events(after: eventCursor, through: cutoffNanoseconds)
        eventCursor = captured.nextIndex
        for event in captured.values {
            if let generation = event.generation {
                state.observeActivation(generation)
            } else {
                state.activationGenerationWasUnavailable()
            }
        }
        if captured.hasIncompleteObservationAtOrBeforeCutoff {
            state.activationGenerationWasUnavailable()
        }
    }

    func awaitAnchorRestoration(deadlineNanoseconds: UInt64) async {
        var restorationCursor = eventCursor
        var restorationDecision = ForegroundRestorationDecision()
        while monotonicNowNanoseconds() < deadlineNanoseconds {
            let recorderSnapshot = recorder.restorationSnapshot(after: restorationCursor)
            restorationCursor = recorderSnapshot.nextIndex
            restorationDecision.drain(recorderSnapshot.values)

            if recorderSnapshot.hasIncompleteObservation {
                _ = await recorder.waitForEvent(
                    after: recorderSnapshot.revision,
                    deadlineNanoseconds: deadlineNanoseconds
                )
                continue
            }

            guard restorationDecision.hasCompletedActivationIntent,
                  restorationDecision.latestCompletedActivationIntent == state.anchor else {
                _ = await recorder.waitForEvent(
                    after: recorderSnapshot.revision,
                    deadlineNanoseconds: deadlineNanoseconds
                )
                continue
            }

            let anchorStatus: ForegroundAnchorGenerationStatus
            do {
                guard let liveIdentity = try kernelProcessUniqueIdentity(for: state.anchor.pid) else {
                    _ = state.observeAnchorRestoration(current: nil, anchorStatus: .exited)
                    return
                }
                anchorStatus = liveIdentity.uniqueId == state.anchor.uniqueId
                    && liveIdentity.pidVersion == state.anchor.pidVersion
                    ? .sameGeneration
                    : .reused
            } catch {
                writeDiagnostic("foreground anchor restoration generation check failed: \(error)")
                state.reject(.anchorGenerationUnavailable)
                return
            }

            let current: ForegroundProcessGeneration?
            do {
                current = try workspace.frontmostApplication.flatMap(foregroundGeneration)
            } catch {
                writeDiagnostic("foreground restoration frontmost check failed: \(error)")
                state.reject(.activationGenerationUnavailable)
                return
            }
            let restorationCandidate = restorationDecision.canAccept(
                anchor: state.anchor,
                frontmost: current,
                hasIncompleteObservation: recorderSnapshot.hasIncompleteObservation,
                recorderSnapshotIsCurrent: true
            )
            if restorationCandidate {
                var sessionCommitFailed = false
                let restorationAccepted = recorder.withCurrentSnapshot(
                    recorderSnapshot,
                    acceptance: {
                        guard !restorationCommitted else {
                            _ = state.observeCommittedAnchorRestoration(
                                current: current,
                                anchorStatus: anchorStatus,
                                sessionCommitAccepted: false
                            )
                            sessionCommitFailed = true
                            return false
                        }
                        let sessionOwnsLease = session.owns(
                            lease,
                            anchor: anchor,
                            continuityToken: continuityToken
                        )
                        let sessionCommitAccepted = sessionOwnsLease
                            && session.commitExactRestoration(
                                lease,
                                cursor: recorderSnapshot.nextIndex,
                                anchor: anchor,
                                continuityToken: continuityToken
                            )
                        guard state.observeCommittedAnchorRestoration(
                            current: current,
                            anchorStatus: anchorStatus,
                            sessionCommitAccepted: sessionCommitAccepted
                        ) else {
                            sessionCommitFailed = true
                            return false
                        }
                        restorationCommitted = true
                        eventCursor = recorderSnapshot.nextIndex
                        return true
                    }
                )
                if restorationAccepted { return }
                if sessionCommitFailed {
                    return
                }
            }
            if anchorStatus == .reused { return }
            _ = await recorder.waitForEvent(
                after: recorderSnapshot.revision,
                deadlineNanoseconds: deadlineNanoseconds
            )
        }
        state.restorationTimedOut()
    }

    var failureReason: ForegroundFailureReason? { state.failureReason }

    var evidence: ForegroundEvidence {
        ForegroundEvidence(
            observerInstalledBeforeLaunch: session.observerIsContinuous(continuityToken),
            anchorGenerationCaptured: true,
            targetGenerationCaptured: state.target != nil,
            targetActivatedBeforeBeacon: state.targetActivatedBeforeBeacon,
            transitionUninterruptedBeforeBeacon: state.transitionUninterruptedBeforeBeacon,
            exactAnchorRestoredAfterCleanup: state.exactAnchorRestoredAfterCleanup,
            reasonCode: state.failureReason
        )
    }

    func finish() {
        guard !finished else { return }
        finished = true
        _ = session.endSample(lease)
    }

    private func throwIfFailed() throws {
        if let reason = state.failureReason {
            throw HarnessError.foregroundInterference(reason)
        }
    }
}

private final class LaunchOwnershipWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let shouldReport = !cancelled
        lock.unlock()
        if shouldReport {
            writeDiagnostic(
                "launch callback deadline elapsed; quarantining the run until LaunchServices returns ownership"
            )
        }
    }
}

private func writeDiagnostic(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func publicFailureCode(_ error: Error) -> String {
    guard let harnessError = error as? HarnessError else { return "unexpected_failure" }
    switch harnessError {
    case .invalidArgument: return "invalid_argument"
    case .io: return "io_failure"
    case .launch: return "launch_failure"
    case .foregroundInterference: return "foreground_interference"
    case .protocolViolation: return "protocol_violation"
    case .timeout: return "timeout"
    case .measurement: return "measurement_failure"
    }
}

private func sampleErrorAfterForegroundRestoration(
    existingSampleError: String?,
    foregroundFailureReason: ForegroundFailureReason?
) -> String? {
    guard foregroundFailureReason != nil else { return existingSampleError }
    return existingSampleError ?? "foreground_interference"
}

private func sampleErrorAfterForegroundFinalization(
    existingSampleError: String?,
    foregroundEvidence: ForegroundEvidence
) -> String? {
    guard !foregroundEvidence.isCompleteForPublication else { return existingSampleError }
    return existingSampleError ?? "foreground_interference"
}

private func abortedReasonAfterForegroundSessionFinalization(
    existingAbortedReason: String?,
    foregroundSessionProofComplete: Bool
) -> String? {
    guard !foregroundSessionProofComplete else { return existingAbortedReason }
    return existingAbortedReason ?? "foreground_session_continuity_unproven"
}

private func benchmarkMeasurementSucceeded(
    abortedReason: String?,
    foregroundSessionProofComplete: Bool,
    samplesContainFailure: Bool
) -> Bool {
    abortedReason == nil
        && foregroundSessionProofComplete
        && !samplesContainFailure
}

@MainActor
private func launch(
    app: AppSpec,
    benchmarkURL: URL,
    token: String,
    measurementTimeoutNanoseconds: UInt64,
    foregroundMonitor: ForegroundSampleMonitor,
    startupTrace: StartupTraceOutput?
) async throws -> LaunchOutcome {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.promptsUserIfNeeded = false
    configuration.addsToRecentItems = false
    configuration.activates = true
    configuration.hides = false
    configuration.arguments = app.argumentTemplates.map {
        $0.replacingOccurrences(of: "{url}", with: benchmarkURL.absoluteString)
            .replacingOccurrences(of: "{token}", with: token)
    }
    var environment = [
        "KELD_BENCH_URL": benchmarkURL.absoluteString,
        "KELD_BENCH_TOKEN": token,
    ]
    if let startupTrace {
        environment[startupTrace.environmentVariable] = startupTrace.fileURL.path
    }
    configuration.environment = environment
    let workspace = NSWorkspace.shared

    return try await withCheckedThrowingContinuation { continuation in
        let ownershipWatchdog = LaunchOwnershipWatchdog()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .nanoseconds(Int(clamping: measurementTimeoutNanoseconds))
        ) { ownershipWatchdog.fire() }
        do {
            try foregroundMonitor.prepareForLaunch()
        } catch {
            ownershipWatchdog.cancel()
            continuation.resume(throwing: error)
            return
        }
        // This clock read is intentionally the statement immediately before the
        // NSWorkspace launch API; setup, URL generation, foreground validation,
        // and environment work are outside the measured interval.
        let t0 = monotonicNowNanoseconds()
        workspace.openApplication(at: app.bundleURL, configuration: configuration) { application, error in
            ownershipWatchdog.cancel()
            if let application {
                let launchedPid = application.processIdentifier
                let kernelOwnership: KernelLaunchOwnership?
                do {
                    kernelOwnership = try kernelLaunchOwnership(for: launchedPid)
                } catch {
                    writeDiagnostic("launch ownership capture failed: \(error)")
                    kernelOwnership = nil
                }
                continuation.resume(returning: LaunchOutcome(
                    application: application,
                    launchedPid: launchedPid,
                    kernelOwnership: kernelOwnership,
                    t0Nanoseconds: t0,
                    callbackNanoseconds: monotonicNowNanoseconds(),
                    wasActiveAtCallback: application.isActive,
                    callbackError: error?.localizedDescription
                ))
            } else if let error {
                continuation.resume(throwing: HarnessError.launch(error.localizedDescription))
            } else {
                continuation.resume(throwing: HarnessError.launch("NSWorkspace returned neither an application nor an error"))
            }
        }
    }
}

private func cleanup(
    application: NSRunningApplication,
    launchedProcessIdentity: StableProcessIdentity,
    expectedBundleFileIdentity: FileIdentity,
    knownCoalitionId: UInt64?,
    reader: ResourceCoalitionReader,
    timeoutNanoseconds: UInt64
) async -> CleanupRecord {
    let pid = launchedProcessIdentity.pid
    var gracefulAccepted = false
    var coalitionHardKillInvoked = false
    var cleanupError: String?
    var coalitionId = knownCoalitionId

    func recordCleanupError(code: String, detail: String) {
        writeDiagnostic("cleanup PID \(pid) [\(code)]: \(detail)")
        if let existing = cleanupError {
            cleanupError = "\(existing);\(code)"
        } else {
            cleanupError = code
        }
    }

    if coalitionId == nil {
        do {
            coalitionId = try reader.identity(for: pid).id
        } catch {
            recordCleanupError(code: "coalition_identity_unavailable", detail: String(describing: error))
        }
    }

    var mainIsLive: Bool?
    do {
        mainIsLive = try reader.processIsSameAndLive(launchedProcessIdentity)
    } catch {
        recordCleanupError(code: "main_process_inspection_failed", detail: String(describing: error))
    }
    if mainIsLive == true {
        do {
            guard let applicationBundleURL = application.bundleURL else {
                throw HarnessError.measurement("LaunchServices omitted the launched bundle URL")
            }
            guard try fileIdentity(at: applicationBundleURL) == expectedBundleFileIdentity else {
                throw HarnessError.measurement("launched bundle file identity changed before cleanup")
            }
            gracefulAccepted = application.terminate()
        } catch {
            recordCleanupError(code: "graceful_cleanup_identity_failed", detail: String(describing: error))
        }
    }

    let started = monotonicNowNanoseconds()
    let gracefulDeadline = started + timeoutNanoseconds / 3
    let finalDeadline = started + timeoutNanoseconds
    var coalitionDrained: Bool?
    while monotonicNowNanoseconds() < gracefulDeadline {
        if let coalitionId {
            do {
                if try reader.coalitionIsEmpty(id: coalitionId) {
                    coalitionDrained = true
                    break
                }
            } catch is CoalitionProcessSetChanged {
                // A PID-only coalition list cannot represent two generations
                // during exit churn. Discard it and require a fresh empty-list
                // observation before cleanup can be proven.
                await nextObservationTick()
                continue
            } catch {
                recordCleanupError(code: "graceful_coalition_inspection_failed", detail: String(describing: error))
                break
            }
        } else if mainIsLive == false {
            break
        }
        await nextObservationTick()
        do {
            mainIsLive = try reader.processIsSameAndLive(launchedProcessIdentity)
        } catch {
            mainIsLive = nil
            recordCleanupError(code: "graceful_cleanup_inspection_failed", detail: String(describing: error))
        }
    }

    if let coalitionId, coalitionDrained != true {
        var hardFailureRecorded = false
        while monotonicNowNanoseconds() < finalDeadline {
            do {
                if try reader.coalitionIsEmpty(id: coalitionId) {
                    coalitionDrained = true
                    break
                }
                coalitionHardKillInvoked = true
                _ = try reader.hardTerminateCoalitionMembers(id: coalitionId)
            } catch is CoalitionProcessSetChanged {
                // Re-enumerate within the existing hard-cleanup deadline. No
                // process from an ambiguous PID list is ever signaled.
            } catch {
                if !hardFailureRecorded {
                    recordCleanupError(code: "hard_cleanup_failed", detail: String(describing: error))
                    hardFailureRecorded = true
                }
            }
            await nextObservationTick()
        }
        if coalitionDrained == nil { coalitionDrained = false }
    } else if coalitionId == nil {
        coalitionDrained = false
    }

    let applicationTerminated: Bool
    do {
        applicationTerminated = try !reader.processIsSameAndLive(launchedProcessIdentity)
    } catch {
        applicationTerminated = false
        recordCleanupError(code: "termination_proof_failed", detail: String(describing: error))
    }
    return CleanupRecord(
        gracefulTerminateAccepted: gracefulAccepted,
        coalitionHardKillInvoked: coalitionHardKillInvoked,
        applicationTerminated: applicationTerminated,
        coalitionDrained: coalitionDrained,
        error: cleanupError
    )
}

private func launchServicesASN(for launchedPid: Int32) throws -> String {
    let result = try runCommand(
        "/usr/bin/lsappinfo",
        ["info", "-only", "ASN", "-app", "#\(launchedPid)"]
    )
    guard result.status == 0 else {
        throw HarnessError.measurement("lsappinfo could not resolve the launch ASN")
    }
    return try parseLaunchServicesASN(result.stdout)
}

private func parseLaunchServicesASN(_ output: String) throws -> String {
    let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "\"LSASN\"="
    guard value.hasPrefix(prefix), value.hasSuffix(":"),
          !value.dropFirst(prefix.count).dropLast().contains(where: { $0.isWhitespace }) else {
        throw HarnessError.measurement("lsappinfo returned malformed ASN output")
    }
    let asn = String(value.dropFirst(prefix.count))
    let body = asn.dropFirst("ASN:".count).dropLast()
    let halves = body.split(separator: "-", omittingEmptySubsequences: false)
    guard asn.hasPrefix("ASN:"), halves.count == 2,
          halves.allSatisfy({ half in
              half.hasPrefix("0x")
                  && half.count > 2
                  && half.dropFirst(2).allSatisfy(\.isHexDigit)
          }) else {
        throw HarnessError.measurement("lsappinfo returned malformed ASN output")
    }
    return asn
}

private func launchServicesOriginalPid(for launchedPid: Int32) throws -> Int32? {
    let result = try runCommand(
        "/usr/bin/lsappinfo",
        ["info", "-only", "originalPid", "-app", "#\(launchedPid)"]
    )
    guard result.status == 0 else {
        throw HarnessError.measurement("lsappinfo could not resolve originalPid for PID \(launchedPid)")
    }
    return try parseLaunchServicesOriginalPid(result.stdout)
}

private func parseLaunchServicesOriginalPid(_ output: String) throws -> Int32? {
    let lines = output.split(whereSeparator: { $0.isNewline })
    guard lines.count == 1,
          let equals = lines[0].firstIndex(of: "=") else {
        throw HarnessError.measurement("lsappinfo returned malformed originalPid output")
    }
    let key = lines[0][..<equals].trimmingCharacters(in: .whitespaces)
    let value = lines[0][lines[0].index(after: equals)...]
        .trimmingCharacters(in: .whitespaces)
    guard key == "\"originalPid\"" else {
        throw HarnessError.measurement("lsappinfo returned the wrong originalPid key")
    }
    if value == "[ NULL ]" { return nil }
    guard let pid = Int32(value), pid > 0 else {
        throw HarnessError.measurement("lsappinfo returned an invalid originalPid value")
    }
    return pid
}

@MainActor
private func runOneSample(
    spec: AppSpec,
    round: Int,
    appOrdinal: Int,
    globalOrdinal: Int,
    options: RunnerOptions,
    server: LoopbackBeaconServer,
    reader: ResourceCoalitionReader,
    foregroundMonitor: ForegroundSampleMonitor
) async -> SampleRecord {
    defer { foregroundMonitor.finish() }
    let hostConditionBeforeLaunch = currentHostCondition()
    let token = UUID().uuidString.lowercased()
    let benchmarkURL = server.url(for: token)
    let timeoutNanoseconds = UInt64(options.timeoutSeconds * 1_000_000_000)
    let cleanupTimeoutNanoseconds = UInt64(options.cleanupTimeoutSeconds * 1_000_000_000)
    var launchOutcome: LaunchOutcome?
    var launchedProcessIdentity: StableProcessIdentity?
    var launchedASN: String?
    var originalPid: Int32?
    var originalPidLookupCompleted = false
    var originalPidMatchesReturnedCoalition: Bool?
    var initialCoalitionIdentity: CoalitionIdentity?
    var acceptedBeacon: BeaconReceipt?
    var snapshot: CoalitionSnapshot?
    var stableObservationCount: Int?
    var paintMilliseconds: Double?
    var wasActiveAtBeacon: Bool?
    var sampleError: String?
    var cleanupRecord: CleanupRecord?
    var cleanupPreparationError: String?
    var foregroundEvidence = ForegroundEvidence.notAttempted
    var startupTraceOutput: StartupTraceOutput?
    var startupTrace: StartupTraceEvidence?
    defer { startupTraceOutput?.remove() }

    do {
        if let environmentVariable = spec.startupTraceEnvironmentVariable {
            startupTraceOutput = try StartupTraceOutput.create(
                environmentVariable: environmentVariable,
                token: token
            )
        }
        try server.activate(token: token)
        let outcome = try await launch(
            app: spec,
            benchmarkURL: benchmarkURL,
            token: token,
            measurementTimeoutNanoseconds: timeoutNanoseconds,
            foregroundMonitor: foregroundMonitor,
            startupTrace: startupTraceOutput
        )
        launchOutcome = outcome
        let rootPid = outcome.launchedPid
        let deadline = outcome.t0Nanoseconds + timeoutNanoseconds
        try foregroundMonitor.bindTarget(outcome.kernelOwnership)
        if let callbackError = outcome.callbackError {
            throw HarnessError.launch(callbackError)
        }
        guard outcome.callbackNanoseconds <= deadline else {
            throw HarnessError.timeout("NSWorkspace launch callback arrived after the sample deadline")
        }
        let beacon = try await server.awaitBeacon(token: token, deadlineNanoseconds: deadline)
        guard beacon.token == token,
              beacon.receivedMonotonicNanoseconds >= outcome.t0Nanoseconds,
              beacon.receivedMonotonicNanoseconds <= deadline else {
            throw HarnessError.protocolViolation("beacon token or timestamp falls outside the sample interval")
        }
        acceptedBeacon = beacon
        wasActiveAtBeacon = outcome.application.isActive
        try foregroundMonitor.acceptBeacon(beacon, targetReportsActive: wasActiveAtBeacon == true)
        paintMilliseconds = Double(beacon.receivedMonotonicNanoseconds - outcome.t0Nanoseconds) / 1_000_000
        server.finish(token: token)
        if let startupTraceOutput {
            startupTrace = try startupTraceOutput.readEvidence()
        }

        // Process enumeration invokes ps/launchctl/lsappinfo and therefore must
        // happen only after the externally timestamped beacon. It cannot
        // perturb the scored launch-to-beacon interval.
        guard let kernelOwnership = outcome.kernelOwnership else {
            throw HarnessError.measurement("launch callback could not capture the process generation")
        }
        let expectedProcessIdentity = try reader.processIdentity(for: rootPid)
        guard expectedProcessIdentity.uniqueId == kernelOwnership.uniqueId else {
            throw HarnessError.measurement("launched process generation changed before measurement")
        }
        launchedProcessIdentity = expectedProcessIdentity
        launchedASN = try launchServicesASN(for: rootPid)
        guard try reader.processIsSameAndLive(expectedProcessIdentity) else {
            throw HarnessError.measurement("launched process generation changed during LaunchServices lookup")
        }
        let expectedCoalitionIdentity = try reader.identity(for: rootPid)
        guard expectedCoalitionIdentity.id == kernelOwnership.resourceCoalitionId else {
            throw HarnessError.measurement("launch callback and LaunchServices reported different resource coalitions")
        }
        initialCoalitionIdentity = expectedCoalitionIdentity
        originalPid = try launchServicesOriginalPid(for: rootPid)
        originalPidLookupCompleted = true
        if let originalPid {
            guard let originalOwnership = try kernelLaunchOwnership(for: originalPid) else {
                throw HarnessError.measurement(
                    "LaunchServices originalPid had no generation-bound resource coalition"
                )
            }
            originalPidMatchesReturnedCoalition = originalOwnership.resourceCoalitionId
                == expectedCoalitionIdentity.id
            guard originalPidMatchesReturnedCoalition == true else {
                throw HarnessError.measurement(
                    "LaunchServices originalPid belongs to a different coalition; launcher handoff is unsupported"
                )
            }
        }

        let stable = try await reader.awaitStableSnapshot(
            for: rootPid,
            expectedProcessIdentity: expectedProcessIdentity,
            expectedCoalitionId: expectedCoalitionIdentity.id,
            deadlineNanoseconds: deadline,
            requiredConsecutiveObservations: options.stableObservations,
            rssToleranceKiB: options.rssToleranceKiB,
            requiredStableNanoseconds: UInt64(options.stableWindowMilliseconds) * 1_000_000
        )
        snapshot = stable.snapshot
        stableObservationCount = stable.observations
    } catch {
        if acceptedBeacon == nil {
            foregroundMonitor.inspectPreBeaconEvents(through: monotonicNowNanoseconds())
        }
        writeDiagnostic("\(spec.label) round \(round) failed: \(error)")
        if let foregroundReason = foregroundMonitor.failureReason {
            writeDiagnostic(
                "\(spec.label) round \(round) foreground contract failed: \(foregroundReason.rawValue)"
            )
            sampleError = "foreground_interference"
        } else if let harnessError = error as? HarnessError,
                  case .foregroundInterference(let reason) = harnessError {
            foregroundEvidence = .captureFailure(reason)
            sampleError = "foreground_interference"
        } else {
            sampleError = publicFailureCode(error)
        }
    }

    // A missing/late beacon still owns a launched application. Resolve its
    // stable identity after the metric has failed so cleanup can prove both the
    // host and reparented coalition helpers drained before returning.
    if let launchOutcome, launchedProcessIdentity == nil {
        let rootPid = launchOutcome.launchedPid
        do {
            guard let kernelOwnership = launchOutcome.kernelOwnership else {
                throw HarnessError.measurement("launch callback did not capture the process generation")
            }
            let identity = try reader.processIdentity(for: rootPid)
            guard identity.uniqueId == kernelOwnership.uniqueId else {
                throw HarnessError.measurement("launched process generation changed before cleanup")
            }
            launchedProcessIdentity = identity
            if launchedASN == nil { launchedASN = try launchServicesASN(for: rootPid) }
            initialCoalitionIdentity = try reader.identity(for: rootPid)
        } catch {
            writeDiagnostic("\(spec.label) round \(round) cleanup preparation failed: \(error)")
            cleanupPreparationError = "process_identity_unavailable"
            if let kernelOwnership = launchOutcome.kernelOwnership {
                launchedProcessIdentity = StableProcessIdentity(
                    pid: kernelOwnership.pid,
                    parentPid: 0,
                    startIdentity: "unavailable-at-launch-callback",
                    uniqueId: kernelOwnership.uniqueId,
                    commandSha256: nil
                )
            }
        }
    }

    if let launchOutcome {
        if let launchedProcessIdentity {
            cleanupRecord = await cleanup(
                application: launchOutcome.application,
                launchedProcessIdentity: launchedProcessIdentity,
                expectedBundleFileIdentity: spec.bundleFileIdentity,
                knownCoalitionId: snapshot?.identity.id
                    ?? initialCoalitionIdentity?.id
                    ?? launchOutcome.kernelOwnership?.resourceCoalitionId,
            reader: reader,
            timeoutNanoseconds: cleanupTimeoutNanoseconds
            )
        } else {
            let gracefulAccepted = launchOutcome.application.terminate()
            cleanupRecord = CleanupRecord(
                gracefulTerminateAccepted: gracefulAccepted,
                coalitionHardKillInvoked: false,
                applicationTerminated: false,
                coalitionDrained: false,
                error: cleanupPreparationError ?? "process_identity_unavailable"
            )
        }
        if cleanupRecord?.applicationTerminated != true
            || cleanupRecord?.coalitionDrained != true
            || cleanupRecord?.error != nil {
            let cleanupFailure = cleanupRecord?.error ?? "cleanup_proof_missing"
            if sampleError == nil { sampleError = "cleanup_failed:\(cleanupFailure)" }
        }
    }
    await foregroundMonitor.awaitAnchorRestoration(
        deadlineNanoseconds: monotonicNowNanoseconds() + cleanupTimeoutNanoseconds
    )
    foregroundEvidence = foregroundMonitor.evidence
    if let reason = foregroundMonitor.failureReason {
        writeDiagnostic(
            "\(spec.label) round \(round) foreground contract failed: \(reason.rawValue)"
        )
        sampleError = sampleErrorAfterForegroundRestoration(
            existingSampleError: sampleError,
            foregroundFailureReason: reason
        )
    }
    server.finish(token: token)
    do {
        try await server.quiesceClientHandlers(
            deadlineNanoseconds: monotonicNowNanoseconds() + 2_000_000_000
        )
    } catch {
        writeDiagnostic("\(spec.label) round \(round) client quiescence failed: \(error)")
        if sampleError == nil { sampleError = "client_handlers_unfinished" }
    }
    sampleError = sampleErrorAfterForegroundFinalization(
        existingSampleError: sampleError,
        foregroundEvidence: foregroundEvidence
    )
    let evidenceContext = launchOutcome.map {
        PublicEvidenceContext(t0MonotonicNanoseconds: $0.t0Nanoseconds)
    }
    let serverEvents = evidenceContext.map { context in
        server.events(for: token).map { ServerEventEvidence($0, context: context) }
    } ?? []
    let hostConditionAfterCleanup = currentHostCondition()

    return SampleRecord(
        globalOrdinal: globalOrdinal,
        round: round,
        appOrdinal: appOrdinal,
        label: spec.label,
        status: sampleError == nil ? "ok" : "failed",
        error: sampleError,
        launchedProcessIdentity: evidenceContext.flatMap { context in
            launchedProcessIdentity.map { StableProcessEvidence($0, context: context) }
        },
        launchServicesASNResolved: launchedASN == nil ? nil : true,
        launchServicesOriginalPidPresent: originalPidLookupCompleted ? originalPid != nil : nil,
        originalPidMatchesReturnedPidCoalition: originalPidMatchesReturnedCoalition,
        launchCallbackOffsetMilliseconds: evidenceContext.flatMap { context in
            launchOutcome.map { context.offsetMilliseconds(for: $0.callbackNanoseconds) }
        },
        applicationWasActiveAtLaunchCallback: launchOutcome?.wasActiveAtCallback,
        applicationWasActiveAtBeacon: wasActiveAtBeacon,
        foreground: foregroundEvidence,
        hostConditionBeforeLaunch: hostConditionBeforeLaunch,
        hostConditionAfterCleanup: hostConditionAfterCleanup,
        beacon: evidenceContext.flatMap { context in
            acceptedBeacon.map { BeaconEvidence($0, context: context) }
        },
        doubleRafPaintOpportunityProxyMilliseconds: paintMilliseconds,
        startupTrace: startupTrace,
        stableCoalitionObservations: stableObservationCount,
        coalition: evidenceContext.flatMap { context in
            snapshot.map { CoalitionEvidence($0, context: context) }
        },
        serverEvents: serverEvents,
        cleanup: cleanupRecord
    )
}

private func metricSummary(_ values: [Double]) -> MetricSummary {
    MetricSummary(
        sampleCount: values.count,
        median: median(values),
        p90NearestRank: nearestRankPercentile(values, percentile: 0.9),
        minimum: values.min(),
        maximum: values.max()
    )
}

private func summarize(apps: [AppSpec], samples: [SampleRecord]) -> [AppSummary] {
    apps.map { app in
        let appSamples = samples.filter { $0.label == app.label }
        let successful = appSamples.filter { $0.status == "ok" }
        return AppSummary(
            label: app.label,
            successfulSamples: successful.count,
            failedSamples: appSamples.count - successful.count,
            doubleRafPaintOpportunityProxyMilliseconds: metricSummary(
                successful.compactMap(\.doubleRafPaintOpportunityProxyMilliseconds)
            ),
            totalCoalitionRssKiB: metricSummary(successful.compactMap { $0.coalition.map { Double($0.totalRssKiB) } })
        )
    }
}

private func hostMetadata() -> HostMetadata {
    let processInfo = ProcessInfo.processInfo
    return HostMetadata(
        operatingSystemVersion: processInfo.operatingSystemVersionString,
        architecture: commandValue("/usr/bin/uname", ["-m"]) ?? "unknown",
        hardwareModel: commandValue("/usr/sbin/sysctl", ["-n", "hw.model"]) ?? "unknown",
        processor: commandValue("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]) ?? "unknown",
        logicalCpuCount: processInfo.processorCount,
        physicalMemoryBytes: processInfo.physicalMemory,
        lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
        thermalState: thermalStateName(processInfo.thermalState)
    )
}

private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

private func currentHostCondition() -> HostConditionEvidence {
    let processInfo = ProcessInfo.processInfo
    return HostConditionEvidence(
        lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
        thermalState: thermalStateName(processInfo.thermalState)
    )
}

private func commandValue(
    _ executable: String,
    _ arguments: [String],
    currentDirectoryURL: URL? = nil
) -> String? {
    guard let result = try? runCommand(
        executable,
        arguments,
        currentDirectoryURL: currentDirectoryURL
    ), result.status == 0 else { return nil }
    let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

private func workingTreeState(from result: CommandResult?) -> GitWorkingTreeState {
    guard let result, result.status == 0 else { return .unavailable }
    return result.stdout.isEmpty ? .clean : .dirty
}

private func isFullGitCommit(_ value: String?) -> Bool {
    guard let value, value.count == 40 || value.count == 64 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
    }
}

private func normalizedRepositoryIdentifier(_ rawValue: String?) -> String? {
    guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    if value.hasPrefix("git@github.com:") {
        value = "github.com/" + value.dropFirst("git@github.com:".count)
    } else if let components = URLComponents(string: value),
              components.host?.lowercased() == "github.com" {
        value = "github.com" + components.path
    } else {
        return nil
    }
    if value.hasSuffix(".git") { value.removeLast(4) }
    while value.hasSuffix("/") { value.removeLast() }
    let pieces = value.split(separator: "/", omittingEmptySubsequences: true)
    guard pieces.count == 3, pieces[0].lowercased() == "github.com" else { return nil }
    return pieces.map(String.init).joined(separator: "/")
}

private struct CanonicalRemoteProbe: Equatable {
    let arguments: [String]
    let currentDirectoryURL: URL
}

private func canonicalRemoteProbe(repositoryIdentifier: String?) -> CanonicalRemoteProbe? {
    let remoteURL: String
    switch repositoryIdentifier {
    case canonicalBenchesRepositoryIdentifier:
        remoteURL = canonicalBenchesRemoteURL
    case canonicalKeldRepositoryIdentifier:
        remoteURL = canonicalKeldRemoteURL
    default:
        return nil
    }
    return CanonicalRemoteProbe(
        arguments: ["-c", "protocol.file.allow=never", "ls-remote", "--heads", remoteURL],
        currentDirectoryURL: canonicalRemoteProbeDirectory
    )
}

private func canonicalRemoteAdvertisesHead(
    commit: String,
    repositoryIdentifier: String?
) -> Bool? {
    guard let probe = canonicalRemoteProbe(repositoryIdentifier: repositoryIdentifier) else {
        return nil
    }
    let result = try? runCommand(
        "/usr/bin/git",
        probe.arguments,
        currentDirectoryURL: probe.currentDirectoryURL,
        timeoutSeconds: 30
    )
    guard let result, result.status == 0 else { return nil }
    return result.stdout.split(whereSeparator: \.isNewline).contains { line in
        let fields = line.split(whereSeparator: \.isWhitespace)
        return fields.count == 2
            && fields[0] == commit
            && fields[1].hasPrefix("refs/heads/")
    }
}

private func gitSnapshot(containing directory: URL) -> GitSnapshot {
    let searchDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
    guard let rootResult = try? runCommand(
        "/usr/bin/git",
        ["-C", searchDirectory.path, "rev-parse", "--show-toplevel"]
    ), rootResult.status == 0 else {
        return GitSnapshot(
            rootURL: nil,
            metadata: RepositoryMetadata(
                identifier: nil,
                commit: nil,
                workingTreeState: .unavailable,
                commitAdvertisedAsOriginHead: nil
            )
        )
    }
    let rootPath = rootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rootPath.isEmpty else {
        return GitSnapshot(
            rootURL: nil,
            metadata: RepositoryMetadata(
                identifier: nil,
                commit: nil,
                workingTreeState: .unavailable,
                commitAdvertisedAsOriginHead: nil
            )
        )
    }
    let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
    let commitResult = try? runCommand(
        "/usr/bin/git",
        ["-C", rootURL.path, "rev-parse", "--verify", "HEAD^{commit}"]
    )
    let commit = commitResult.flatMap { result -> String? in
        guard result.status == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return isFullGitCommit(value) ? value : nil
    }
    let statusResult = try? runCommand(
        "/usr/bin/git",
        [
            "-c", "core.fsmonitor=false",
            "-c", "core.untrackedCache=false",
            "-c", "core.fileMode=true",
            "-C", rootURL.path,
            "status", "--porcelain=v1", "--untracked-files=all",
        ]
    )
    let indexFlagsResult = try? runCommand(
        "/usr/bin/git",
        ["-C", rootURL.path, "ls-files", "-v"]
    )
    let indexFlagsAreDefault = indexFlagsResult.map { result in
        result.status == 0 && result.stdout.split(whereSeparator: \.isNewline).allSatisfy { line in
            line.first == "H"
        }
    } ?? false
    let remote = commandValue(
        "/usr/bin/git",
        ["-C", rootURL.path, "remote", "get-url", "origin"]
    )
    let repositoryIdentifier = normalizedRepositoryIdentifier(remote)
    let advertisedAsOriginHead = commit.flatMap {
        canonicalRemoteAdvertisesHead(commit: $0, repositoryIdentifier: repositoryIdentifier)
    }
    let state = commit == nil || !indexFlagsAreDefault
        ? GitWorkingTreeState.unavailable
        : workingTreeState(from: statusResult)
    return GitSnapshot(
        rootURL: rootURL,
        metadata: RepositoryMetadata(
            identifier: repositoryIdentifier,
            commit: commit,
            workingTreeState: state,
            commitAdvertisedAsOriginHead: advertisedAsOriginHead
        )
    )
}

private func repositoryRelativePath(of url: URL, within root: URL) -> String? {
    let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
    let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    if resolvedURL.path == resolvedRoot.path { return "." }
    let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
    guard resolvedURL.path.hasPrefix(prefix) else { return nil }
    return String(resolvedURL.path.dropFirst(prefix.count))
}

private func hashFile(
    _ url: URL,
    relativeTo root: URL,
    snapshotCommit: String
) throws -> ArtifactHash {
    guard let relativePath = repositoryRelativePath(of: url, within: root) else {
        throw HarnessError.io("source file is outside the resolved repository")
    }
    let data = try Data(contentsOf: url)
    let headResult = try? runCommand(
        "/usr/bin/git",
        [
            "-C", root.path,
            "rev-parse", "--verify", "\(snapshotCommit):\(relativePath)",
        ]
    )
    let headObjectId = headResult.flatMap { result -> String? in
        guard result.status == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return isFullGitCommit(value) ? value : nil
    }
    let matchesHeadBlob = headObjectId.map {
        rawGitBlobObjectId(data, hexadecimalLength: $0.count) == $0
    } ?? false
    return ArtifactHash(
        repositoryRelativePath: relativePath,
        sha256: sha256Hex(data),
        matchesHeadBlob: matchesHeadBlob
    )
}

private struct ImmutableGitBlob {
    let objectId: String
    let data: Data
}

private func immutableGitBlob(
    repositoryRoot: URL,
    commit: String,
    relativePath: String
) throws -> ImmutableGitBlob {
    guard isFullGitCommit(commit),
          !relativePath.isEmpty,
          !relativePath.hasPrefix("/"),
          !relativePath.split(separator: "/").contains("..") else {
        throw HarnessError.io("invalid immutable source path \(relativePath)")
    }
    let objectResult = try runCommand(
        "/usr/bin/git",
        ["-C", repositoryRoot.path, "rev-parse", "--verify", "\(commit):\(relativePath)"]
    )
    guard objectResult.status == 0 else {
        throw HarnessError.io("HEAD blob is unavailable for \(relativePath)")
    }
    let objectId = objectResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isFullGitCommit(objectId) else {
        throw HarnessError.io("Git returned a malformed blob ID for \(relativePath)")
    }
    let typeResult = try runCommand(
        "/usr/bin/git",
        ["-C", repositoryRoot.path, "cat-file", "-t", "\(commit):\(relativePath)"]
    )
    guard typeResult.status == 0,
          typeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "blob" else {
        throw HarnessError.io("HEAD path is not a regular blob: \(relativePath)")
    }
    let dataResult = try runCommand(
        "/usr/bin/git",
        ["-C", repositoryRoot.path, "cat-file", "blob", "\(commit):\(relativePath)"],
        timeoutSeconds: 30
    )
    guard dataResult.status == 0 else {
        throw HarnessError.io("Git could not read the immutable blob \(relativePath)")
    }
    guard rawGitBlobObjectId(dataResult.stdoutData, hexadecimalLength: objectId.count) == objectId else {
        throw HarnessError.io("raw Git blob verification failed for \(relativePath)")
    }
    return ImmutableGitBlob(objectId: objectId, data: dataResult.stdoutData)
}

private func materializeImmutableGitTree(
    repositoryRoot: URL,
    commit: String,
    relativePaths: [String],
    destinationRoot: URL
) throws -> [ArtifactHash] {
    try FileManager.default.createDirectory(
        at: destinationRoot,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    guard Darwin.chmod(destinationRoot.path, 0o700) == 0 else {
        throw HarnessError.io("could not make the immutable source tree private")
    }
    var hashes: [ArtifactHash] = []
    for relativePath in relativePaths.sorted() {
        let blob = try immutableGitBlob(
            repositoryRoot: repositoryRoot,
            commit: commit,
            relativePath: relativePath
        )
        let destination = destinationRoot.appendingPathComponent(relativePath)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard Darwin.chmod(parent.path, 0o700) == 0 else {
            throw HarnessError.io("could not make an immutable source directory private")
        }
        try blob.data.write(to: destination, options: .withoutOverwriting)
        guard Darwin.chmod(destination.path, 0o600) == 0 else {
            throw HarnessError.io("could not make an immutable source file private")
        }
        let materialized = try Data(contentsOf: destination, options: .mappedIfSafe)
        guard rawGitBlobObjectId(materialized, hexadecimalLength: blob.objectId.count) == blob.objectId,
              sha256Hex(materialized) == sha256Hex(blob.data) else {
            throw HarnessError.io("immutable source materialization changed \(relativePath)")
        }
        hashes.append(ArtifactHash(
            repositoryRelativePath: relativePath,
            sha256: sha256Hex(materialized),
            matchesHeadBlob: true
        ))
    }
    return hashes
}

private func descriptorPathReplacementControl(in temporaryRoot: URL) throws -> Bool {
    let originalURL = temporaryRoot.appendingPathComponent("descriptor-original")
    let replacementURL = temporaryRoot.appendingPathComponent("descriptor-replacement")
    let retainedURL = temporaryRoot.appendingPathComponent("descriptor-retained")
    let originalData = Data("original descriptor bytes\n".utf8)
    let replacementData = Data("replacement path bytes\n".utf8)
    try originalData.write(to: originalURL)
    try replacementData.write(to: replacementURL)
    let descriptor = Darwin.open(originalURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw HarnessError.io("descriptor replacement control could not open its original")
    }
    defer { Darwin.close(descriptor) }
    let identity = try descriptorSnapshot(descriptor, label: "descriptor replacement control").identity
    try FileManager.default.moveItem(at: originalURL, to: retainedURL)
    try FileManager.default.copyItem(at: replacementURL, to: originalURL)
    let replacementIdentity = try descriptorFileIdentity(at: originalURL)
    guard !descriptorIdentityMatchesMappedIdentity(
        descriptorIdentity: replacementIdentity,
        mappedIdentity: identity
    ) else {
        return false
    }
    let observed = try readStableDescriptorData(
        descriptor,
        expectedIdentity: identity,
        label: "descriptor replacement control"
    ).data
    return observed == originalData
}

private func nearestTauriSourceRoot(from appURL: URL, repositoryRoot: URL?) -> URL? {
    guard let repositoryRoot else { return nil }
    let resolvedRoot = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
    let rootPrefix = resolvedRoot.path.hasSuffix("/")
        ? resolvedRoot.path
        : resolvedRoot.path + "/"
    var candidate = appURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    while candidate.path == resolvedRoot.path || candidate.path.hasPrefix(rootPrefix) {
        let package = candidate.appendingPathComponent("package.json")
        let bunLock = candidate.appendingPathComponent("bun.lock")
        let cargo = candidate.appendingPathComponent("src-tauri/Cargo.toml")
        if FileManager.default.fileExists(atPath: package.path),
           FileManager.default.fileExists(atPath: bunLock.path),
           FileManager.default.fileExists(atPath: cargo.path) {
            return candidate
        }
        guard candidate.path != resolvedRoot.path else { break }
        let parent = candidate.deletingLastPathComponent()
        guard parent.path != candidate.path else { break }
        candidate = parent
    }
    return nil
}

private func observedHarnessToolchain() -> ObservedToolchainMetadata {
    ObservedToolchainMetadata(
        evidenceKind: "observed-at-benchmark",
        swiftCompilerVersion: commandValue("/usr/bin/xcrun", ["swiftc", "--version"]),
        xcodeVersion: commandValue("/usr/bin/xcodebuild", ["-version"]),
        macosSdkVersion: commandValue("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-version"]),
        bunVersion: nil,
        tauriCliVersion: nil,
        rustcVersion: nil,
        cargoVersion: nil
    )
}

private func fixtureToolchain(
    bundle: Bundle?,
    tauriSourceRoot: URL?
) -> ObservedToolchainMetadata {
    let embeddedBun = bundle?.object(forInfoDictionaryKey: "KeldBenchBunVersion") as? String
    let embeddedTauri = bundle?.object(forInfoDictionaryKey: "KeldBenchTauriCLIVersion") as? String
    let embeddedRustc = bundle?.object(forInfoDictionaryKey: "KeldBenchRustcVersion") as? String
    let embeddedCargo = bundle?.object(forInfoDictionaryKey: "KeldBenchCargoVersion") as? String
    let embeddedSdk = bundle?.object(forInfoDictionaryKey: "KeldBenchMacOSSDKVersion") as? String
    let embeddedXcode = bundle?.object(forInfoDictionaryKey: "KeldBenchXcodeVersion") as? String
    if embeddedBun != nil || embeddedTauri != nil || embeddedRustc != nil
        || embeddedCargo != nil || embeddedSdk != nil || embeddedXcode != nil {
        return ObservedToolchainMetadata(
            evidenceKind: "embedded-build-metadata",
            swiftCompilerVersion: nil,
            xcodeVersion: embeddedXcode,
            macosSdkVersion: embeddedSdk,
            bunVersion: embeddedBun,
            tauriCliVersion: embeddedTauri,
            rustcVersion: embeddedRustc,
            cargoVersion: embeddedCargo
        )
    }
    let tauriVersion = tauriSourceRoot.flatMap { sourceRoot in
        commandValue(
            "/usr/bin/env",
            ["bun", "run", "tauri", "--version"],
            currentDirectoryURL: sourceRoot
        )
    }
    return ObservedToolchainMetadata(
        evidenceKind: "observed-at-benchmark-and-lock-bound",
        swiftCompilerVersion: nil,
        xcodeVersion: commandValue("/usr/bin/xcodebuild", ["-version"]),
        macosSdkVersion: commandValue("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-version"]),
        bunVersion: commandValue(
            "/usr/bin/env",
            ["bun", "--version"],
            currentDirectoryURL: tauriSourceRoot
        ),
        tauriCliVersion: tauriVersion,
        rustcVersion: commandValue(
            "/usr/bin/env",
            ["rustc", "-Vv"],
            currentDirectoryURL: tauriSourceRoot
        ),
        cargoVersion: commandValue(
            "/usr/bin/env",
            ["cargo", "-V"],
            currentDirectoryURL: tauriSourceRoot
        )
    )
}

private func fixtureMetadata(_ spec: AppSpec) throws -> FixtureMetadata {
    let bundle = Bundle(url: spec.bundleURL)
    let executableURL = bundle?.executableURL
    var executableSize: UInt64?
    var executableSha256: String?
    if let path = executableURL?.path,
       let attributes = try? FileManager.default.attributesOfItem(atPath: path),
       let size = attributes[.size] as? NSNumber {
        executableSize = size.uint64Value
        executableSha256 = try? sha256Hex(Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe))
    }
    let sourceSnapshot = gitSnapshot(containing: spec.bundleURL)
    let tauriSourceRoot = nearestTauriSourceRoot(
        from: spec.bundleURL,
        repositoryRoot: sourceSnapshot.rootURL
    )
    var sourceFiles: [ArtifactHash] = []
    var lockfiles: [ArtifactHash] = []
    if let sourceRoot = sourceSnapshot.rootURL,
       let tauriSourceRoot,
       let sourceCommit = sourceSnapshot.metadata.commit {
        for relativePath in requiredTauriSourcePaths {
            let sourceFile = tauriSourceRoot.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: sourceFile.path) {
                sourceFiles.append(try hashFile(
                    sourceFile,
                    relativeTo: sourceRoot,
                    snapshotCommit: sourceCommit
                ))
            }
        }
        for lockfile in [
            tauriSourceRoot.appendingPathComponent("bun.lock"),
            tauriSourceRoot.appendingPathComponent("src-tauri/Cargo.lock"),
        ] where FileManager.default.fileExists(atPath: lockfile.path) {
            lockfiles.append(try hashFile(
                lockfile,
                relativeTo: sourceRoot,
                snapshotCommit: sourceCommit
            ))
        }
    }
    let embeddedSourceCommit = bundle?.object(forInfoDictionaryKey: "KeldBenchSourceCommit") as? String
    let embeddedSourceRepository = bundle?.object(forInfoDictionaryKey: "KeldBenchSourceRepository") as? String
    let embeddedFixtureKind = bundle?.object(forInfoDictionaryKey: "KeldBenchFixtureKind") as? String
    let embeddedSourceRelativePath = bundle?
        .object(forInfoDictionaryKey: "KeldBenchSourceRelativePath") as? String
    let embeddedRecipeRepository = bundle?.object(forInfoDictionaryKey: "KeldBenchRecipeRepository") as? String
    let embeddedRecipeCommit = bundle?.object(forInfoDictionaryKey: "KeldBenchRecipeCommit") as? String
    let embeddedBuildRecipe = bundle?.object(forInfoDictionaryKey: "KeldBenchBuildRecipe") as? String
    let sourceDirectory = tauriSourceRoot ?? spec.bundleURL
    let sourceRelativePath = sourceSnapshot.rootURL.flatMap {
        repositoryRelativePath(of: sourceDirectory, within: $0)
    }
    let executableRelativePath = executableURL.flatMap {
        repositoryRelativePath(of: $0, within: spec.bundleURL)
    }
    let buildCommand = spec.buildCommand ?? ""
    return FixtureMetadata(
        label: spec.label,
        appBundleName: spec.bundleURL.lastPathComponent,
        bundleIdentifier: bundle?.bundleIdentifier,
        bundleVersion: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        appBundleTreeSha256: try bundleTreeSha256(spec.bundleURL),
        executableBundleRelativePath: executableRelativePath,
        executableSizeBytes: executableSize,
        executableSha256: executableSha256,
        sourceRepository: sourceSnapshot.metadata,
        sourceRepositoryRelativePath: sourceRelativePath,
        embeddedFixtureKind: embeddedFixtureKind
            ?? (embeddedSourceRepository == canonicalKeldRepositoryIdentifier
                ? "keld-adapter"
                : nil),
        embeddedSourceRepositoryIdentifier: embeddedSourceRepository,
        embeddedSourceGitCommit: embeddedSourceCommit,
        embeddedSourceRepositoryRelativePath: embeddedSourceRelativePath,
        embeddedSourceCommitAdvertisedAsOriginHead: embeddedSourceCommit.flatMap {
            canonicalRemoteAdvertisesHead(
                commit: $0,
                repositoryIdentifier: embeddedSourceRepository
            )
        },
        embeddedRecipeRepositoryIdentifier: embeddedRecipeRepository,
        embeddedRecipeGitCommit: embeddedRecipeCommit,
        embeddedBuildRecipeIdentifier: embeddedBuildRecipe,
        adapterPatchSha256: bundle?.object(forInfoDictionaryKey: "KeldBenchAdapterPatchSHA256") as? String,
        buildScriptSha256: bundle?.object(forInfoDictionaryKey: "KeldBenchBuildScriptSHA256") as? String,
        infoPlistTemplateSha256: bundle?.object(forInfoDictionaryKey: "KeldBenchInfoPlistTemplateSHA256") as? String,
        buildCommandSha256: sha256Hex(Data(buildCommand.utf8)),
        argumentTemplateSha256: spec.argumentTemplates.map { sha256Hex(Data($0.utf8)) },
        sourceFiles: sourceFiles.sorted { $0.repositoryRelativePath < $1.repositoryRelativePath },
        lockfiles: lockfiles.sorted { $0.repositoryRelativePath < $1.repositoryRelativePath },
        toolchain: fixtureToolchain(bundle: bundle, tauriSourceRoot: tauriSourceRoot)
    )
}

private let harnessBuildInvocationContract = "xcrun swiftc -O -parse-as-library -strict-concurrency=complete -warn-concurrency -warnings-as-errors -o macos/harness/.build/keld-macos-bench macos/harness/HarnessCore.swift macos/harness/Runner.swift"

private let harnessCompiledSourcePaths = [
    "macos/harness/HarnessCore.swift",
    "macos/harness/Runner.swift",
]

private let harnessProvenanceSourcePaths = harnessCompiledSourcePaths + [
    "macos/harness/hello.html",
    "macos/harness/test-fixtures/stubborn/Info.plist",
    "macos/harness/test-fixtures/stubborn/main.swift",
    "macos/keld/hello/Info.plist",
    "macos/keld/hello/build.sh",
    "macos/keld/hello/keld-bench-url.patch",
    "macos/tauri/hello/build.sh",
]

private func reproducibleHarnessBuildEvidence(
    executableBinding: LoadedExecutableBinding,
    repositoryRoot: URL?,
    sourceCommit: String?
) throws -> HarnessRebuildEvidence {
    guard let repositoryRoot else {
        return HarnessRebuildEvidence(
            attempted: false,
            rebuiltExecutableSha256: nil,
            byteForByteMatchesRunningExecutable: false,
            loadedExecutableBoundToMappedVnode: executableBinding.isBoundToMappedVnode,
            pathReplacementRejected: false,
            immutableHeadBlobTreeVerified: false,
            transientLiveSourceSubstitutionRejected: false
        )
    }
    guard let commit = sourceCommit else {
        return HarnessRebuildEvidence(
            attempted: false,
            rebuiltExecutableSha256: nil,
            byteForByteMatchesRunningExecutable: true,
            loadedExecutableBoundToMappedVnode: executableBinding.isBoundToMappedVnode,
            pathReplacementRejected: false,
            immutableHeadBlobTreeVerified: false,
            transientLiveSourceSubstitutionRejected: false
        )
    }
    guard harnessCompiledSourcePaths.count >= 2 else {
        throw HarnessError.io("reproducible build requires at least two compiled harness sources")
    }

    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("keld-harness-rebuild-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: temporaryRoot,
        withIntermediateDirectories: false
    )
    defer {
        do {
            try FileManager.default.removeItem(at: temporaryRoot)
        } catch {
            writeDiagnostic("harness reproducible-build temporary cleanup failed")
        }
    }

    let resolvedTemporaryRoot = temporaryRoot.standardizedFileURL.resolvingSymlinksInPath()
    guard !path(resolvedTemporaryRoot, isWithinOrEqualTo: repositoryRoot) else {
        throw HarnessError.io("reproducible-build temporary tree must be outside the source repository")
    }

    let runningData = try executableBinding.readData()
    let pathReplacementRejected = try descriptorPathReplacementControl(in: temporaryRoot)
    let sourceRoot = temporaryRoot
    let immutableSourceFiles = try materializeImmutableGitTree(
        repositoryRoot: repositoryRoot,
        commit: commit,
        relativePaths: harnessProvenanceSourcePaths,
        destinationRoot: sourceRoot
    )
    let immutableSourceHashes = Dictionary(
        uniqueKeysWithValues: immutableSourceFiles.map {
            ($0.repositoryRelativePath, $0.sha256)
        }
    )
    guard harnessCompiledSourcePaths.allSatisfy({ immutableSourceHashes[$0] != nil }) else {
        throw HarnessError.io("immutable source tree omitted a compiled harness source")
    }

    let rebuiltExecutable = temporaryRoot.appendingPathComponent("keld-macos-bench")
    let arguments = [
        "swiftc", "-O", "-parse-as-library",
        "-strict-concurrency=complete", "-warn-concurrency", "-warnings-as-errors",
        "-o", rebuiltExecutable.path,
    ] + harnessCompiledSourcePaths

    let liveSourceRoot = temporaryRoot.appendingPathComponent("live-source", isDirectory: true)
    let liveSubstitutionPath = liveSourceRoot.appendingPathComponent(harnessCompiledSourcePaths[0])
    try FileManager.default.createDirectory(
        at: liveSubstitutionPath.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let immutableSourcePath = sourceRoot.appendingPathComponent(harnessCompiledSourcePaths[0])
    let liveSource = try Data(contentsOf: immutableSourcePath, options: .mappedIfSafe)
    try liveSource.write(to: liveSubstitutionPath, options: .withoutOverwriting)
    let invalidLiveSubstitution = Data("this is an intentionally invalid live-source substitution\n".utf8)
    guard invalidLiveSubstitution != liveSource else {
        throw HarnessError.io("live-source substitution marker unexpectedly matches the source")
    }
    try invalidLiveSubstitution.write(to: liveSubstitutionPath, options: .atomic)
    let liveControlOutput = temporaryRoot.appendingPathComponent("live-source-control")
    let liveControlArguments = [
        "swiftc", "-O", "-parse-as-library",
        "-strict-concurrency=complete", "-warn-concurrency", "-warnings-as-errors",
        "-o", liveControlOutput.path,
        liveSubstitutionPath.path,
        temporaryRoot.appendingPathComponent(harnessCompiledSourcePaths[1]).path,
    ]
    let liveControl = try runCommand(
        "/usr/bin/xcrun",
        liveControlArguments,
        currentDirectoryURL: temporaryRoot,
        timeoutSeconds: 120
    )
    let compile = try runCommand(
        "/usr/bin/xcrun",
        arguments,
        currentDirectoryURL: temporaryRoot,
        timeoutSeconds: 120
    )
    let immutableSourceAfter = try Data(contentsOf: immutableSourcePath, options: .mappedIfSafe)
    let transientLiveSourceSubstitutionRejected =
        (try? Data(contentsOf: liveSubstitutionPath, options: .mappedIfSafe)) == invalidLiveSubstitution
        && liveControl.status != 0
        && compile.status == 0
        && immutableSourceAfter == liveSource
    guard compile.status == 0 else {
        writeDiagnostic("harness reproducible build exited with status \(compile.status)")
        return HarnessRebuildEvidence(
            attempted: true,
            rebuiltExecutableSha256: nil,
            byteForByteMatchesRunningExecutable: false,
            loadedExecutableBoundToMappedVnode: executableBinding.isBoundToMappedVnode,
            pathReplacementRejected: pathReplacementRejected,
            immutableHeadBlobTreeVerified: false,
            transientLiveSourceSubstitutionRejected: transientLiveSourceSubstitutionRejected
        )
    }

    let rebuiltData = try Data(contentsOf: rebuiltExecutable, options: .mappedIfSafe)
    let immutableHeadBlobTreeVerified = immutableSourceFiles.count == harnessProvenanceSourcePaths.count
        && immutableSourceFiles.allSatisfy { $0.matchesHeadBlob && isSha256($0.sha256) }
    return HarnessRebuildEvidence(
        attempted: true,
        rebuiltExecutableSha256: sha256Hex(rebuiltData),
        byteForByteMatchesRunningExecutable: rebuiltData == runningData,
        loadedExecutableBoundToMappedVnode: executableBinding.isBoundToMappedVnode,
        pathReplacementRejected: pathReplacementRejected,
        immutableHeadBlobTreeVerified: immutableHeadBlobTreeVerified,
        transientLiveSourceSubstitutionRejected: transientLiveSourceSubstitutionRejected
    )
}

private func harnessArtifactMetadata(
    executableBinding: LoadedExecutableBinding,
    repository: GitSnapshot
) throws -> HarnessArtifactMetadata {
    var sourceFiles: [ArtifactHash] = []
    if let root = repository.rootURL, let commit = repository.metadata.commit {
        for relativePath in harnessProvenanceSourcePaths {
            let blob = try immutableGitBlob(
                repositoryRoot: root,
                commit: commit,
                relativePath: relativePath
            )
            sourceFiles.append(ArtifactHash(
                repositoryRelativePath: relativePath,
                sha256: sha256Hex(blob.data),
                matchesHeadBlob: true
            ))
        }
    }
    let executableData = try executableBinding.readData()
    let reproducibleBuild = try reproducibleHarnessBuildEvidence(
        executableBinding: executableBinding,
        repositoryRoot: repository.rootURL,
        sourceCommit: repository.metadata.commit
    )
    return HarnessArtifactMetadata(
        executableSizeBytes: UInt64(executableData.count),
        executableSha256: sha256Hex(executableData),
        buildInvocationContract: harnessBuildInvocationContract,
        reproducibleBuild: reproducibleBuild,
        sourceRepository: repository.metadata,
        sourceFiles: sourceFiles,
        observedToolchain: observedHarnessToolchain()
    )
}

private func parseOptions(_ arguments: [String]) throws -> RunnerOptions {
    var options = RunnerOptions()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--app":
            index += 1
            guard index < arguments.count else { throw HarnessError.invalidArgument("--app requires LABEL=/path/App.app") }
            let value = arguments[index]
            guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
                throw HarnessError.invalidArgument("--app requires LABEL=/path/App.app")
            }
            let label = String(value[..<separator])
            let path = String(value[value.index(after: separator)...])
            guard isPublicLabel(label) else {
                throw HarnessError.invalidArgument("app labels must use 1-64 ASCII letters, digits, spaces, periods, underscores, or hyphens")
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path) else {
                throw HarnessError.invalidArgument("\(url.path) is not an existing .app bundle")
            }
            guard Bundle(url: url)?.executableURL != nil else {
                throw HarnessError.invalidArgument("\(url.path) has no bundle executable")
            }
            guard !options.apps.contains(where: { $0.label == label }) else {
                throw HarnessError.invalidArgument("duplicate app label \(label)")
            }
            options.apps.append(AppSpec(
                label: label,
                bundleURL: url,
                bundleFileIdentity: try fileIdentity(at: url),
                argumentTemplates: [],
                buildCommand: nil,
                startupTraceEnvironmentVariable: nil
            ))
        case "--app-arg":
            index += 1
            guard index < arguments.count else { throw HarnessError.invalidArgument("--app-arg requires LABEL=ARGUMENT_TEMPLATE") }
            let value = arguments[index]
            guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
                throw HarnessError.invalidArgument("--app-arg requires LABEL=ARGUMENT_TEMPLATE")
            }
            let label = String(value[..<separator])
            let template = String(value[value.index(after: separator)...])
            guard !template.isEmpty else { throw HarnessError.invalidArgument("--app-arg template must not be empty") }
            options.argumentTemplatesByLabel[label, default: []].append(template)
        case "--app-build-command":
            index += 1
            guard index < arguments.count else { throw HarnessError.invalidArgument("--app-build-command requires LABEL=COMMAND") }
            let value = arguments[index]
            guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
                throw HarnessError.invalidArgument("--app-build-command requires LABEL=COMMAND")
            }
            let label = String(value[..<separator])
            let command = String(value[value.index(after: separator)...])
            guard !command.isEmpty else { throw HarnessError.invalidArgument("build command must not be empty") }
            options.buildCommandsByLabel[label] = command
        case "--app-startup-trace":
            index += 1
            guard index < arguments.count else {
                throw HarnessError.invalidArgument("--app-startup-trace requires LABEL=ENVIRONMENT_VARIABLE")
            }
            let value = arguments[index]
            guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
                throw HarnessError.invalidArgument("--app-startup-trace requires LABEL=ENVIRONMENT_VARIABLE")
            }
            let label = String(value[..<separator])
            let environmentVariable = String(value[value.index(after: separator)...])
            guard isEnvironmentVariableName(environmentVariable) else {
                throw HarnessError.invalidArgument("--app-startup-trace environment variable must be uppercase ASCII with underscores")
            }
            guard options.startupTraceEnvironmentVariablesByLabel[label] == nil else {
                throw HarnessError.invalidArgument("duplicate --app-startup-trace label \(label)")
            }
            options.startupTraceEnvironmentVariablesByLabel[label] = environmentVariable
        case "--runs":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), (1...1_000).contains(value) else {
                throw HarnessError.invalidArgument("--runs must be an integer from 1 through 1000")
            }
            options.runsPerApp = value
        case "--timeout-seconds":
            index += 1
            guard index < arguments.count,
                  let value = Double(arguments[index]),
                  value.isFinite,
                  value > 0,
                  value <= 600 else {
                throw HarnessError.invalidArgument("--timeout-seconds must be finite and in (0, 600]")
            }
            options.timeoutSeconds = value
        case "--cleanup-timeout-seconds":
            index += 1
            guard index < arguments.count,
                  let value = Double(arguments[index]),
                  value.isFinite,
                  value > 0,
                  value <= 60 else {
                throw HarnessError.invalidArgument("--cleanup-timeout-seconds must be finite and in (0, 60]")
            }
            options.cleanupTimeoutSeconds = value
        case "--stable-observations":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), (2...100).contains(value) else {
                throw HarnessError.invalidArgument("--stable-observations must be an integer from 2 through 100")
            }
            options.stableObservations = value
        case "--stable-window-ms":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), (100...60_000).contains(value) else {
                throw HarnessError.invalidArgument("--stable-window-ms must be an integer from 100 through 60000")
            }
            options.stableWindowMilliseconds = value
        case "--rss-tolerance-kib":
            index += 1
            guard index < arguments.count, let value = UInt64(arguments[index]) else {
                throw HarnessError.invalidArgument("--rss-tolerance-kib must be an unsigned integer")
            }
            options.rssToleranceKiB = value
        case "--html":
            index += 1
            guard index < arguments.count else { throw HarnessError.invalidArgument("--html requires a path") }
            options.htmlURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
        case "--output":
            index += 1
            guard index < arguments.count else { throw HarnessError.invalidArgument("--output requires a path") }
            options.outputURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
        case "--publish":
            options.publish = true
        case "--self-test":
            options.selfTest = true
        case "--help", "-h":
            options.showHelp = true
        default:
            throw HarnessError.invalidArgument("unknown option \(argument)")
        }
        index += 1
    }
    for (label, templates) in options.argumentTemplatesByLabel {
        guard let appIndex = options.apps.firstIndex(where: { $0.label == label }) else {
            throw HarnessError.invalidArgument("--app-arg refers to unknown app label \(label)")
        }
        options.apps[appIndex].argumentTemplates = templates
    }
    for (label, environmentVariable) in options.startupTraceEnvironmentVariablesByLabel {
        guard let appIndex = options.apps.firstIndex(where: { $0.label == label }) else {
            throw HarnessError.invalidArgument("--app-startup-trace refers to unknown app label \(label)")
        }
        options.apps[appIndex].startupTraceEnvironmentVariable = environmentVariable
    }
    for appIndex in options.apps.indices {
        let label = options.apps[appIndex].label
        let embeddedCommand = Bundle(url: options.apps[appIndex].bundleURL)?
            .object(forInfoDictionaryKey: "KeldBenchBuildRecipe") as? String
        guard let command = options.buildCommandsByLabel[label] ?? embeddedCommand else {
            throw HarnessError.invalidArgument("--app-build-command is required for \(label)")
        }
        options.apps[appIndex].buildCommand = command
    }
    let unknownBuildLabels = Set(options.buildCommandsByLabel.keys).subtracting(options.apps.map(\.label))
    guard unknownBuildLabels.isEmpty else {
        throw HarnessError.invalidArgument("--app-build-command refers to unknown labels: \(unknownBuildLabels.sorted().joined(separator: ", "))")
    }
    let unknownTraceLabels = Set(options.startupTraceEnvironmentVariablesByLabel.keys)
        .subtracting(options.apps.map(\.label))
    guard unknownTraceLabels.isEmpty else {
        throw HarnessError.invalidArgument("--app-startup-trace refers to unknown labels: \(unknownTraceLabels.sorted().joined(separator: ", "))")
    }
    return options
}

private func resolveHTMLURL(_ explicit: URL?) throws -> URL {
    if let explicit {
        guard FileManager.default.fileExists(atPath: explicit.path) else {
            throw HarnessError.invalidArgument("canonical HTML does not exist at \(explicit.path)")
        }
        return explicit
    }

    let executable = try loadedExecutableURL()
    let candidates = [
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("macos/harness/hello.html"),
        executable.deletingLastPathComponent().appendingPathComponent("hello.html"),
        executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("hello.html"),
    ]
    guard let match = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
        throw HarnessError.invalidArgument("could not find macos/harness/hello.html; pass --html")
    }
    return match.standardizedFileURL
}

private func printUsage() {
    let usage = """
    Usage:
      keld-macos-bench --app LABEL=/absolute/App.app [--app LABEL=/absolute/Other.app] [options]
      keld-macos-bench --self-test [--html /path/to/hello.html]

    Options:
      --runs N                       Samples per app (default: 11)
      --app-arg LABEL=TEMPLATE        Replace that app's launch arguments; {url} and {token} expand per run
      --app-build-command LABEL=TEXT   Required exact build-command provenance for that app
      --app-startup-trace LABEL=ENV    Collect a private fixture startup trace through ENV; diagnostic only
      --timeout-seconds N             Measurement deadline; launch ownership is never abandoned (default: 30)
      --cleanup-timeout-seconds N     Cleanup kill-switch deadline (default: 5)
      --stable-observations N         Consecutive stable coalition reads (default: 3)
      --stable-window-ms N            Sustained member/RSS stability window (default: 500)
      --rss-tolerance-kib N           Allowed RSS drift between stable reads (default: 1024)
      --html PATH                     Canonical hello.html (auto-discovered by default)
      --output PATH                   Also atomically write raw JSON to PATH
      --publish                       Enforce the machine-readable publication policy
      --self-test                     Run protocol/parser negative controls
      --help                          Show this text
    """
    print(usage)
}

private struct PublicationArmFacts {
    let label: String
    let sampleCount: Int
    let successfulSampleCount: Int
    let completeCleanupCount: Int
    let completeMetricCount: Int
    let completeForegroundCount: Int
    let fixtureUnchanged: Bool
    let provenanceComplete: Bool
    let adapterRecipeMatches: Bool
    let toolchainComplete: Bool
    let publicArgumentsSafe: Bool
    let sampleHostConditionsAcceptable: Bool
}

private struct PublicationFacts {
    let runsPerApp: Int
    let stableCoalitionObservations: Int
    let stableCoalitionWindowMilliseconds: Int
    let rssToleranceKiB: UInt64
    let repositoryBefore: RepositoryMetadata
    let repositoryAfter: RepositoryMetadata
    let harnessProvenanceComplete: Bool
    let canonicalHTML: Bool
    let publicationOutputProvided: Bool
    let outputWillPreserveCleanTree: Bool
    let hostBefore: HostMetadata
    let hostAfter: HostMetadata
    let aborted: Bool
    let foregroundSessionProofComplete: Bool
    let recordedSampleCount: Int
    let foregroundSessionStartedSampleCount: Int
    let foregroundSessionExactRestorationCount: Int
    let foregroundSessionFinishedSampleCount: Int
    let arms: [PublicationArmFacts]
}

private func hostMetadataIsComplete(_ host: HostMetadata) -> Bool {
    let requiredStrings = [
        host.operatingSystemVersion,
        host.architecture,
        host.hardwareModel,
        host.processor,
    ]
    return requiredStrings.allSatisfy {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && $0.lowercased() != "unknown"
    }
        && host.logicalCpuCount > 0
        && host.physicalMemoryBytes > 0
        && ["nominal", "fair", "serious", "critical"].contains(host.thermalState)
}

private func publicationAssessment(
    requested: Bool,
    facts: PublicationFacts
) -> PublicationMetadata {
    var reasons: [PublicationReason] = []
    func append(_ code: String, label: String? = nil) {
        reasons.append(PublicationReason(code: code, label: label))
    }

    if facts.runsPerApp != 11 { append("runs_per_arm_not_11") }
    if facts.stableCoalitionObservations < 3
        || facts.stableCoalitionWindowMilliseconds < 500
        || facts.rssToleranceKiB > 1_024 {
        append("rss_stability_policy_weakened")
    }
    let before = facts.repositoryBefore
    let after = facts.repositoryAfter
    if before.workingTreeState == .unavailable || after.workingTreeState == .unavailable
        || !isFullGitCommit(before.commit) || !isFullGitCommit(after.commit)
        || before.identifier == nil || after.identifier == nil {
        append("repository_unavailable")
    } else {
        if before.identifier != canonicalBenchesRepositoryIdentifier
            || after.identifier != canonicalBenchesRepositoryIdentifier {
            append("repository_not_canonical")
        }
        if before.commitAdvertisedAsOriginHead != true || after.commitAdvertisedAsOriginHead != true {
            append("repository_commit_not_advertised_as_origin_head")
        }
        if before.workingTreeState == .dirty || after.workingTreeState == .dirty {
            append("repository_dirty")
        }
        if before.commit != after.commit || before.identifier != after.identifier {
            append("repository_changed")
        }
    }
    if !facts.harnessProvenanceComplete { append("harness_provenance_missing") }
    if !facts.canonicalHTML { append("canonical_html_mismatch") }
    if !facts.publicationOutputProvided {
        append("publication_output_missing")
    } else if !facts.outputWillPreserveCleanTree {
        append("output_would_dirty_repository")
    }
    if !hostMetadataIsComplete(facts.hostBefore) || !hostMetadataIsComplete(facts.hostAfter) {
        append("host_metadata_unavailable")
    }
    if facts.hostBefore.lowPowerModeEnabled || facts.hostAfter.lowPowerModeEnabled {
        append("low_power_mode_enabled")
    }
    if facts.hostBefore.thermalState != "nominal" || facts.hostAfter.thermalState != "nominal" {
        append("thermal_state_not_nominal")
    }
    if facts.hostBefore != facts.hostAfter { append("host_state_changed") }
    if facts.aborted { append("aborted") }
    let foregroundSessionCountsMatchRecords = facts.recordedSampleCount > 0
        && facts.foregroundSessionStartedSampleCount == facts.recordedSampleCount
        && facts.foregroundSessionExactRestorationCount == facts.recordedSampleCount
        && facts.foregroundSessionFinishedSampleCount == facts.recordedSampleCount
    if !facts.foregroundSessionProofComplete || !foregroundSessionCountsMatchRecords {
        append("foreground_session_proof_missing")
    }
    for arm in facts.arms {
        if arm.sampleCount != 11 { append("sample_count_mismatch", label: arm.label) }
        if arm.successfulSampleCount != arm.sampleCount { append("sample_failed", label: arm.label) }
        if arm.completeCleanupCount != arm.sampleCount { append("cleanup_unproven", label: arm.label) }
        if arm.completeMetricCount != arm.sampleCount { append("metric_missing", label: arm.label) }
        if arm.completeForegroundCount != arm.sampleCount {
            append("foreground_proof_missing", label: arm.label)
        }
        if !arm.fixtureUnchanged { append("fixture_changed", label: arm.label) }
        if !arm.provenanceComplete { append("fixture_provenance_missing", label: arm.label) }
        if !arm.adapterRecipeMatches { append("fixture_adapter_recipe_mismatch", label: arm.label) }
        if !arm.toolchainComplete { append("toolchain_evidence_missing", label: arm.label) }
        if !arm.publicArgumentsSafe { append("unsafe_public_argument", label: arm.label) }
        if !arm.sampleHostConditionsAcceptable {
            append("sample_host_state_not_nominal", label: arm.label)
        }
    }
    return PublicationMetadata(
        policyVersion: 4,
        requested: requested,
        eligible: reasons.isEmpty,
        reasons: reasons
    )
}

private func isSha256(_ value: String?) -> Bool {
    guard let value, value.count == 64 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
    }
}

private func isNonemptyMetadataValue(_ value: String?) -> Bool {
    guard let value else { return false }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func isPublicArgumentTemplate(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 256, !value.contains("/"), !value.contains("\\") else {
        return false
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_=.:{}")
    return value.unicodeScalars.allSatisfy(allowed.contains)
}

private func isPublicLabel(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 64 else { return false }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-")
    return value.unicodeScalars.allSatisfy(allowed.contains)
}

private func isEnvironmentVariableName(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first,
          CharacterSet.uppercaseLetters.contains(first),
          value.utf8.count <= 64 else {
        return false
    }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    return value.unicodeScalars.allSatisfy(allowed.contains)
}

private func isPublicBundleName(_ value: String) -> Bool {
    isPublicLabel(String(value.dropLast(value.hasSuffix(".app") ? 4 : 0)))
        && value.hasSuffix(".app")
}

private func repositoryMetadataIsPublishable(_ metadata: RepositoryMetadata?) -> Bool {
    guard let metadata else { return false }
    return metadata.identifier == canonicalBenchesRepositoryIdentifier
        && isFullGitCommit(metadata.commit)
        && metadata.workingTreeState == .clean
        && metadata.commitAdvertisedAsOriginHead == true
}

private func fixtureProvenanceIsComplete(_ fixture: FixtureMetadata) -> Bool {
    guard isSha256(fixture.appBundleTreeSha256),
          isPublicLabel(fixture.label),
          isPublicBundleName(fixture.appBundleName),
          isSha256(fixture.executableSha256),
          fixture.executableSizeBytes != nil,
          fixture.executableBundleRelativePath != nil,
          isSha256(fixture.buildCommandSha256) else {
        return false
    }
    switch fixture.embeddedFixtureKind {
    case "keld-adapter":
        guard let embeddedCommit = fixture.embeddedSourceGitCommit else { return false }
        return isFullGitCommit(embeddedCommit)
            && fixture.embeddedSourceRepositoryIdentifier == canonicalKeldRepositoryIdentifier
            && fixture.embeddedSourceCommitAdvertisedAsOriginHead == true
            && fixture.embeddedRecipeRepositoryIdentifier == canonicalBenchesRepositoryIdentifier
            && isFullGitCommit(fixture.embeddedRecipeGitCommit)
            && fixture.embeddedBuildRecipeIdentifier == "macos/keld/hello/build.sh SOURCE SHA OUTPUT_APP"
            && isSha256(fixture.adapterPatchSha256)
            && isSha256(fixture.buildScriptSha256)
            && isSha256(fixture.infoPlistTemplateSha256)
    case "tauri":
        guard let sourceRoot = fixture.sourceRepositoryRelativePath,
              sourceRoot == "macos/tauri/hello",
              fixture.embeddedSourceRepositoryRelativePath == sourceRoot,
              let sourceCommit = fixture.sourceRepository?.commit else {
            return false
        }
        let sourcePrefix = sourceRoot + "/"
        let expectedSourcePaths = Set(requiredTauriSourcePaths.map { sourcePrefix + $0 })
        let observedSourcePaths = Set(fixture.sourceFiles.map(\.repositoryRelativePath))
        let lockfileNames = Set(fixture.lockfiles.map(\.repositoryRelativePath))
        return repositoryMetadataIsPublishable(fixture.sourceRepository)
            && fixture.embeddedSourceRepositoryIdentifier == canonicalBenchesRepositoryIdentifier
            && fixture.embeddedSourceGitCommit == sourceCommit
            && fixture.embeddedSourceCommitAdvertisedAsOriginHead == true
            && fixture.embeddedRecipeRepositoryIdentifier == canonicalBenchesRepositoryIdentifier
            && fixture.embeddedRecipeGitCommit == sourceCommit
            && fixture.embeddedBuildRecipeIdentifier == "macos/tauri/hello/build.sh"
            && isSha256(fixture.buildScriptSha256)
            && observedSourcePaths == expectedSourcePaths
            && fixture.sourceFiles.allSatisfy { isSha256($0.sha256) && $0.matchesHeadBlob }
            && lockfileNames == Set([
                "macos/tauri/hello/bun.lock",
                "macos/tauri/hello/src-tauri/Cargo.lock",
            ])
            && fixture.lockfiles.allSatisfy { isSha256($0.sha256) && $0.matchesHeadBlob }
    default:
        return false
    }
}

private func embeddedAdapterRecipeMatches(
    fixture: FixtureMetadata,
    harness: HarnessArtifactMetadata
) -> Bool {
    switch fixture.embeddedFixtureKind {
    case "keld-adapter":
        return embeddedAdapterRecipeFieldsMatch(
            recipeRepository: fixture.embeddedRecipeRepositoryIdentifier,
            recipeCommit: fixture.embeddedRecipeGitCommit,
            buildRecipe: fixture.embeddedBuildRecipeIdentifier,
            patchSha256: fixture.adapterPatchSha256,
            buildScriptSha256: fixture.buildScriptSha256,
            infoPlistSha256: fixture.infoPlistTemplateSha256,
            harnessCommit: harness.sourceRepository.commit,
            sourceFiles: harness.sourceFiles
        ) && fixture.buildCommandSha256 == sha256Hex(
            Data("macos/keld/hello/build.sh SOURCE SHA OUTPUT_APP".utf8)
        )
    case "tauri":
        return embeddedTauriRecipeFieldsMatch(
            sourceRepository: fixture.embeddedSourceRepositoryIdentifier,
            sourceCommit: fixture.embeddedSourceGitCommit,
            sourceRelativePath: fixture.embeddedSourceRepositoryRelativePath,
            recipeRepository: fixture.embeddedRecipeRepositoryIdentifier,
            recipeCommit: fixture.embeddedRecipeGitCommit,
            buildRecipe: fixture.embeddedBuildRecipeIdentifier,
            buildScriptSha256: fixture.buildScriptSha256,
            buildCommandSha256: fixture.buildCommandSha256,
            harnessCommit: harness.sourceRepository.commit,
            sourceFiles: harness.sourceFiles
        )
    default:
        return false
    }
}

private func embeddedAdapterRecipeFieldsMatch(
    recipeRepository: String?,
    recipeCommit: String?,
    buildRecipe: String?,
    patchSha256: String?,
    buildScriptSha256: String?,
    infoPlistSha256: String?,
    harnessCommit: String?,
    sourceFiles: [ArtifactHash]
) -> Bool {
    let sourceHashes = Dictionary(
        uniqueKeysWithValues: sourceFiles.map { ($0.repositoryRelativePath, $0.sha256) }
    )
    return recipeRepository == canonicalBenchesRepositoryIdentifier
        && recipeCommit == harnessCommit
        && buildRecipe == "macos/keld/hello/build.sh SOURCE SHA OUTPUT_APP"
        && patchSha256 == sourceHashes["macos/keld/hello/keld-bench-url.patch"]
        && buildScriptSha256 == sourceHashes["macos/keld/hello/build.sh"]
        && infoPlistSha256 == sourceHashes["macos/keld/hello/Info.plist"]
}

private func embeddedTauriRecipeFieldsMatch(
    sourceRepository: String?,
    sourceCommit: String?,
    sourceRelativePath: String?,
    recipeRepository: String?,
    recipeCommit: String?,
    buildRecipe: String?,
    buildScriptSha256: String?,
    buildCommandSha256: String,
    harnessCommit: String?,
    sourceFiles: [ArtifactHash]
) -> Bool {
    let sourceHashes = Dictionary(
        uniqueKeysWithValues: sourceFiles.map { ($0.repositoryRelativePath, $0.sha256) }
    )
    return sourceRepository == canonicalBenchesRepositoryIdentifier
        && sourceCommit == harnessCommit
        && sourceRelativePath == "macos/tauri/hello"
        && recipeRepository == canonicalBenchesRepositoryIdentifier
        && recipeCommit == harnessCommit
        && buildRecipe == "macos/tauri/hello/build.sh"
        && buildScriptSha256 == sourceHashes["macos/tauri/hello/build.sh"]
        && buildCommandSha256 == sha256Hex(Data("macos/tauri/hello/build.sh".utf8))
}

private func fixtureToolchainIsComplete(_ fixture: FixtureMetadata) -> Bool {
    let toolchain = fixture.toolchain
    switch fixture.embeddedFixtureKind {
    case "keld-adapter":
        return toolchain.evidenceKind == "embedded-build-metadata"
            && isNonemptyMetadataValue(toolchain.rustcVersion)
            && isNonemptyMetadataValue(toolchain.cargoVersion)
            && isNonemptyMetadataValue(toolchain.macosSdkVersion)
            && isNonemptyMetadataValue(toolchain.xcodeVersion)
    case "tauri":
        return toolchain.evidenceKind == "embedded-build-metadata"
            && isNonemptyMetadataValue(toolchain.bunVersion)
            && isNonemptyMetadataValue(toolchain.tauriCliVersion)
            && isNonemptyMetadataValue(toolchain.rustcVersion)
            && isNonemptyMetadataValue(toolchain.cargoVersion)
            && isNonemptyMetadataValue(toolchain.macosSdkVersion)
            && isNonemptyMetadataValue(toolchain.xcodeVersion)
    default:
        return false
    }
}

private func harnessRebuildEvidenceIsValid(
    _ evidence: HarnessRebuildEvidence,
    executableSha256: String
) -> Bool {
    evidence.attempted
        && evidence.byteForByteMatchesRunningExecutable
        && evidence.rebuiltExecutableSha256 == executableSha256
        && evidence.loadedExecutableBoundToMappedVnode
        && evidence.pathReplacementRejected
        && evidence.immutableHeadBlobTreeVerified
        && evidence.transientLiveSourceSubstitutionRejected
}

private func harnessProvenanceIsComplete(_ harness: HarnessArtifactMetadata) -> Bool {
    let paths = Set(harness.sourceFiles.map(\.repositoryRelativePath))
    return repositoryMetadataIsPublishable(harness.sourceRepository)
        && isSha256(harness.executableSha256)
        && harness.executableSizeBytes > 0
        && harness.buildInvocationContract == harnessBuildInvocationContract
        && harnessRebuildEvidenceIsValid(
            harness.reproducibleBuild,
            executableSha256: harness.executableSha256
        )
        && paths == Set(harnessProvenanceSourcePaths)
        && harness.sourceFiles.allSatisfy { isSha256($0.sha256) && $0.matchesHeadBlob }
        && isNonemptyMetadataValue(harness.observedToolchain.swiftCompilerVersion)
        && isNonemptyMetadataValue(harness.observedToolchain.xcodeVersion)
        && isNonemptyMetadataValue(harness.observedToolchain.macosSdkVersion)
}

private func path(_ candidate: URL, isWithinOrEqualTo root: URL) -> Bool {
    let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
    let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
    if candidatePath == rootPath { return true }
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    return candidatePath.hasPrefix(prefix)
}

private final class ValidatedOutputDestination: @unchecked Sendable {
    let url: URL
    private let directoryURL: URL
    private let directoryFileIdentity: FileIdentity
    private let directoryDescriptor: Int32
    private let fileName: String

    init(
        url: URL,
        directoryURL: URL,
        directoryFileIdentity: FileIdentity,
        directoryDescriptor: Int32,
        fileName: String
    ) {
        self.url = url
        self.directoryURL = directoryURL
        self.directoryFileIdentity = directoryFileIdentity
        self.directoryDescriptor = directoryDescriptor
        self.fileName = fileName
    }

    deinit {
        Darwin.close(directoryDescriptor)
    }

    func write(_ data: Data) throws {
        guard try fileIdentity(at: directoryURL) == directoryFileIdentity else {
            throw HarnessError.io("--output parent changed during the benchmark")
        }
        try requireDirectoryOutsideGitWorkingTree(directoryURL)

        let temporaryName = ".\(fileName).tmp.\(UUID().uuidString.lowercased())"
        let descriptor = Darwin.openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw HarnessError.io("could not exclusively create the publication output")
        }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
            _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
        }
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw HarnessError.io("could not write the publication output")
                }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw HarnessError.io("could not sync the publication output")
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw HarnessError.io("could not close the publication output")
        }
        descriptorIsOpen = false
        guard Darwin.renameatx_np(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            fileName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw HarnessError.io("could not atomically install the publication output without overwriting")
        }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw HarnessError.io("could not sync the publication output directory")
        }
    }
}

private func emitBenchmarkJSON(
    _ json: Data,
    outputDestination: ValidatedOutputDestination?,
    standardOutput: FileHandle = .standardOutput,
    standardError: FileHandle = .standardError
) throws {
    if let outputDestination {
        try outputDestination.write(json)
        standardError.write(Data("raw JSON: \(outputDestination.url.path)\n".utf8))
    }
    standardOutput.write(json)
    standardOutput.write(Data("\n".utf8))
}

private func requireDirectoryOutsideGitWorkingTree(_ directory: URL) throws {
    var candidatePath = directory.standardizedFileURL.resolvingSymlinksInPath().path
    while true {
        let markerPath = (candidatePath as NSString).appendingPathComponent(".git")
        var markerInformation = stat()
        errno = 0
        if Darwin.lstat(markerPath, &markerInformation) == 0 {
            throw HarnessError.invalidArgument("--output must be outside every Git working tree")
        }
        guard errno == ENOENT else {
            throw HarnessError.io(
                "could not prove --output is outside a Git working tree (Git marker errno \(errno))"
            )
        }
        let parentPath = (candidatePath as NSString).deletingLastPathComponent
        if parentPath.isEmpty || parentPath == candidatePath { return }
        candidatePath = parentPath
    }
}

private func validatedOutputURL(
    _ requested: URL?,
    repositoryRoot: URL?,
    harnessExecutable: URL,
    htmlURL: URL,
    apps: [AppSpec]
) throws -> ValidatedOutputDestination? {
    guard let requested else { return nil }
    let parent = requested.deletingLastPathComponent()
        .standardizedFileURL
        .resolvingSymlinksInPath()
    let parentDescriptor = Darwin.open(parent.path, O_RDONLY | O_CLOEXEC)
    guard parentDescriptor >= 0 else {
        throw HarnessError.invalidArgument("--output parent must be an existing directory")
    }
    var parentInformation = stat()
    guard Darwin.fstat(parentDescriptor, &parentInformation) == 0,
          parentInformation.st_mode & S_IFMT == S_IFDIR else {
        Darwin.close(parentDescriptor)
        throw HarnessError.invalidArgument("--output parent must be an existing directory")
    }
    let parentIdentity = FileIdentity(
        device: UInt64(parentInformation.st_dev),
        inode: UInt64(parentInformation.st_ino)
    )
    let output = parent.appendingPathComponent(requested.lastPathComponent).standardizedFileURL
    var outputInformation = stat()
    errno = 0
    if Darwin.fstatat(parentDescriptor, requested.lastPathComponent, &outputInformation, AT_SYMLINK_NOFOLLOW) == 0 {
        Darwin.close(parentDescriptor)
        throw HarnessError.invalidArgument("--output must not already exist")
    }
    guard errno == ENOENT else {
        Darwin.close(parentDescriptor)
        throw HarnessError.io("could not inspect --output destination")
    }
    guard output.path != harnessExecutable.standardizedFileURL.resolvingSymlinksInPath().path,
          output.path != htmlURL.standardizedFileURL.resolvingSymlinksInPath().path else {
        Darwin.close(parentDescriptor)
        throw HarnessError.invalidArgument("--output must not replace a benchmark input")
    }
    guard !apps.contains(where: { path(output, isWithinOrEqualTo: $0.bundleURL) }) else {
        Darwin.close(parentDescriptor)
        throw HarnessError.invalidArgument("--output must be outside every measured app bundle")
    }
    if let repositoryRoot, path(output, isWithinOrEqualTo: repositoryRoot) {
        Darwin.close(parentDescriptor)
        throw HarnessError.invalidArgument("--output must be outside the benchmark repository")
    }
    do {
        try requireDirectoryOutsideGitWorkingTree(parent)
    } catch {
        Darwin.close(parentDescriptor)
        throw error
    }
    return ValidatedOutputDestination(
        url: output,
        directoryURL: parent,
        directoryFileIdentity: parentIdentity,
        directoryDescriptor: parentDescriptor,
        fileName: requested.lastPathComponent
    )
}

private func connectedLoopbackSocket(port: UInt16) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw HarnessError.io("self-test socket failed") }

    var noSignal: Int32 = 1
    guard setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        Darwin.close(descriptor)
        throw HarnessError.io("self-test socket configuration failed")
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        Darwin.close(descriptor)
        throw HarnessError.io("self-test connect failed")
    }
    return descriptor
}

private func rawHTTPStatus(port: UInt16, request: String) throws -> Int {
    let descriptor = try connectedLoopbackSocket(port: port)
    defer { Darwin.close(descriptor) }

    let requestData = Data(request.utf8)
    requestData.withUnsafeBytes { buffer in
        if let base = buffer.baseAddress { _ = Darwin.send(descriptor, base, buffer.count, 0) }
    }
    var buffer = [UInt8](repeating: 0, count: 256)
    let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
    guard count > 0,
          let line = String(bytes: buffer.prefix(Int(count)), encoding: .utf8)?
          .components(separatedBy: "\r\n").first else {
        throw HarnessError.io("self-test received no HTTP status")
    }
    let fields = line.split(separator: " ")
    guard fields.count >= 2, let status = Int(fields[1]) else {
        throw HarnessError.io("self-test received malformed HTTP status")
    }
    return status
}

private func rawHTTPStatus(port: UInt16, target: String) throws -> Int {
    try rawHTTPStatus(
        port: port,
        request: "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
    )
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw HarnessError.measurement("self-test failed: \(message)") }
}

@MainActor
private func validateForegroundTransitionContract() throws {
    let anchor = ForegroundProcessGeneration(pid: 101, uniqueId: 1_001, pidVersion: 11)
    let target = ForegroundProcessGeneration(pid: 202, uniqueId: 2_002, pidVersion: 22)
    let foreign = ForegroundProcessGeneration(pid: 303, uniqueId: 3_003, pidVersion: 33)
    func beginTestObservation(
        _ recorder: ForegroundActivationRecorder
    ) throws -> ForegroundActivationRecorder.ObservationHandle {
        guard let observation = recorder.beginObservation() else {
            throw HarnessError.measurement(
                "self-test failed: foreground recorder closed before the test observation"
            )
        }
        return observation
    }

    var clean = ForegroundTransitionState(anchor: anchor)
    clean.prepareForLaunch(current: anchor)
    clean.bindTarget(target)
    clean.observeActivation(target)
    clean.acceptBeacon(targetReportsActive: true)
    try require(
        clean.beaconAccepted
            && clean.targetActivatedBeforeBeacon
            && clean.transitionUninterruptedBeforeBeacon
            && clean.failureReason == nil,
        "the clean anchor-to-target transition must be accepted"
    )
    clean.observeActivation(foreign)
    try require(
        !clean.observeAnchorRestoration(current: foreign, anchorStatus: .sameGeneration),
        "a transient post-cleanup foreground app must not count as anchor restoration"
    )
    try require(
        clean.observeAnchorRestoration(current: anchor, anchorStatus: .sameGeneration)
            && clean.exactAnchorRestoredAfterCleanup,
        "the exact original anchor generation must complete restoration"
    )

    var anchorChangedBeforeLaunch = ForegroundTransitionState(anchor: anchor)
    anchorChangedBeforeLaunch.prepareForLaunch(current: foreign)
    try require(
        anchorChangedBeforeLaunch.failureReason == .anchorChangedBeforeLaunch
            && !anchorChangedBeforeLaunch.beaconAccepted,
        "a changed pre-launch foreground generation must fail with its stable reason"
    )

    var foreignBeforeTarget = ForegroundTransitionState(anchor: anchor)
    foreignBeforeTarget.prepareForLaunch(current: anchor)
    foreignBeforeTarget.bindTarget(target)
    foreignBeforeTarget.observeActivation(foreign)
    try require(
        foreignBeforeTarget.failureReason == .foreignApplicationBeforeTarget
            && !foreignBeforeTarget.targetActivatedBeforeBeacon,
        "a foreign activation before the target must fail with its stable reason"
    )

    var foreignSteal = ForegroundTransitionState(anchor: anchor)
    foreignSteal.prepareForLaunch(current: anchor)
    foreignSteal.bindTarget(target)
    foreignSteal.observeActivation(target)
    foreignSteal.observeActivation(foreign)
    foreignSteal.acceptBeacon(targetReportsActive: false)
    try require(
        foreignSteal.failureReason == .targetLostToForeignBeforeBeacon
            && !foreignSteal.beaconAccepted,
        "a foreign foreground steal before the beacon must fail with its stable reason"
    )

    // Ordering sensitivity: model a synchronous observer callback that began
    // before the beacon but finishes generation capture after beacon
    // validation starts. The in-flight marker must fail closed; completing the
    // foreign event later cannot turn the sample into a success.
    let delayedRecorder = ForegroundActivationRecorder()
    let preBeaconObservation = try beginTestObservation(delayedRecorder)
    let postBeaconObservation = try beginTestObservation(delayedRecorder)
    let postBeaconGeneration = ForegroundProcessGeneration(
        pid: 404,
        uniqueId: 4_004,
        pidVersion: 44
    )
    delayedRecorder.completeObservation(
        postBeaconObservation.id,
        generation: postBeaconGeneration
    )
    let atBeacon = delayedRecorder.events(
        after: 0,
        through: preBeaconObservation.monotonicNanoseconds
    )
    var delayedForeignSteal = ForegroundTransitionState(anchor: anchor)
    delayedForeignSteal.prepareForLaunch(current: anchor)
    delayedForeignSteal.bindTarget(target)
    delayedForeignSteal.observeActivation(target)
    if atBeacon.hasIncompleteObservationAtOrBeforeCutoff {
        delayedForeignSteal.activationGenerationWasUnavailable()
    }
    delayedRecorder.completeObservation(preBeaconObservation.id, generation: foreign)
    delayedForeignSteal.acceptBeacon(targetReportsActive: true)
    let deliveredAfterBeacon = delayedRecorder.events(
        after: atBeacon.nextIndex,
        through: UInt64.max
    )
    try require(
        delayedForeignSteal.failureReason == .activationGenerationUnavailable
            && !delayedForeignSteal.beaconAccepted
            && atBeacon.values.isEmpty
            && atBeacon.nextIndex == 0
            && deliveredAfterBeacon.values.count == 2
            && deliveredAfterBeacon.values[0].generation == foreign
            && deliveredAfterBeacon.values[1].generation == postBeaconGeneration,
        "reverse callback completion must not hide a pre-beacon foreign steal behind a post-beacon slot"
    )

    // Restoration sensitivity: NSWorkspace can publish an activation intent
    // before frontmostApplication reflects it. A stale anchor snapshot must not
    // pass while a foreign intent is pending or is the latest completed slot.
    // A later exact-anchor intent may pass only while that recorder snapshot
    // remains unchanged through the frontmost-generation check.
    let restorationRecorder = ForegroundActivationRecorder()
    var restorationDecision = ForegroundRestorationDecision()
    var restorationCursor = 0
    let pendingForeignIntent = try beginTestObservation(restorationRecorder)
    var restorationSnapshot = restorationRecorder.restorationSnapshot(
        after: restorationCursor
    )
    restorationCursor = restorationSnapshot.nextIndex
    restorationDecision.drain(restorationSnapshot.values)
    try require(
        !restorationDecision.canAccept(
            anchor: anchor,
            frontmost: anchor,
            hasIncompleteObservation: restorationSnapshot.hasIncompleteObservation,
            recorderSnapshotIsCurrent: restorationRecorder.restorationSnapshotIsCurrent(
                restorationSnapshot
            )
        ),
        "a pending foreign activation intent must defeat a stale anchor frontmost snapshot"
    )

    restorationRecorder.completeObservation(pendingForeignIntent.id, generation: foreign)
    restorationSnapshot = restorationRecorder.restorationSnapshot(after: restorationCursor)
    restorationCursor = restorationSnapshot.nextIndex
    restorationDecision.drain(restorationSnapshot.values)
    try require(
        restorationDecision.latestCompletedActivationIntent == foreign
            && !restorationDecision.canAccept(
                anchor: anchor,
                frontmost: anchor,
                hasIncompleteObservation: restorationSnapshot.hasIncompleteObservation,
                recorderSnapshotIsCurrent: restorationRecorder.restorationSnapshotIsCurrent(
                    restorationSnapshot
                )
            ),
        "a completed foreign activation intent must defeat a stale anchor frontmost snapshot"
    )

    let exactAnchorIntent = try beginTestObservation(restorationRecorder)
    restorationRecorder.completeObservation(exactAnchorIntent.id, generation: anchor)
    restorationSnapshot = restorationRecorder.restorationSnapshot(after: restorationCursor)
    restorationCursor = restorationSnapshot.nextIndex
    restorationDecision.drain(restorationSnapshot.values)
    try require(
        restorationDecision.canAccept(
            anchor: anchor,
            frontmost: anchor,
            hasIncompleteObservation: restorationSnapshot.hasIncompleteObservation,
            recorderSnapshotIsCurrent: restorationRecorder.restorationSnapshotIsCurrent(
                restorationSnapshot
            )
        ),
        "a subsequent exact-anchor intent plus an exact stable frontmost generation must restore"
    )

    let foreignAfterFrontmostSnapshot = try beginTestObservation(restorationRecorder)
    try require(
        !restorationDecision.canAccept(
            anchor: anchor,
            frontmost: anchor,
            hasIncompleteObservation: restorationSnapshot.hasIncompleteObservation,
            recorderSnapshotIsCurrent: restorationRecorder.restorationSnapshotIsCurrent(
                restorationSnapshot
            )
        ),
        "a recorder revision or pending-slot change after the frontmost query must defeat restoration"
    )
    restorationRecorder.completeObservation(
        foreignAfterFrontmostSnapshot.id,
        generation: foreign
    )

    // Session continuity: committing exact restoration advances only the
    // shared cursor. The lease remains active until explicit sample finish, so
    // no second sample can overlap post-restoration finalization.
    var sessionCursor = ForegroundSessionCursorState(
        anchor: anchor,
        committedCursor: 0
    )
    guard let firstLease = sessionCursor.beginSample() else {
        throw HarnessError.measurement("self-test failed: first foreground lease was unavailable")
    }
    let wrongLease = ForegroundSampleLease(
        id: firstLease.id + 10,
        startCursor: firstLease.startCursor
    )
    try require(
        sessionCursor.beginSample() == nil
            && !sessionCursor.commit(wrongLease, cursor: 1)
            && !sessionCursor.end(wrongLease),
        "duplicate begin and wrong-lease commit/end must be rejected"
    )

    let sessionRecorder = ForegroundActivationRecorder()
    let firstAnchorRestoration = try beginTestObservation(sessionRecorder)
    sessionRecorder.completeObservation(firstAnchorRestoration.id, generation: anchor)
    let acceptedFirstRestoration = sessionRecorder.restorationSnapshot(after: 0)
    try require(
        sessionRecorder.restorationSnapshotIsCurrent(acceptedFirstRestoration)
            && sessionCursor.commit(
                firstLease,
                cursor: acceptedFirstRestoration.nextIndex
            )
            && sessionCursor.activeLease == firstLease
            && sessionCursor.beginSample() == nil,
        "exact restoration must advance the cursor without releasing the first sample lease"
    )

    let foreignBetweenSamples = try beginTestObservation(sessionRecorder)
    sessionRecorder.completeObservation(foreignBetweenSamples.id, generation: foreign)
    try require(
        sessionCursor.end(firstLease),
        "the first sample must explicitly release its lease after finalization"
    )
    guard let secondLease = sessionCursor.beginSample() else {
        throw HarnessError.measurement("self-test failed: second foreground lease was unavailable")
    }
    try require(
        secondLease.startCursor == acceptedFirstRestoration.nextIndex,
        "sample two must start at the exact restoration cursor committed by sample one"
    )
    let secondSampleEvents = sessionRecorder.restorationSnapshot(
        after: secondLease.startCursor
    )
    var immutableSessionAnchor = ForegroundTransitionState(anchor: anchor)
    for event in secondSampleEvents.values {
        immutableSessionAnchor.observeBetweenSampleActivation(event.generation)
    }
    immutableSessionAnchor.prepareForLaunch(current: anchor)
    var omittedBetweenSampleEvent = ForegroundTransitionState(anchor: anchor)
    omittedBetweenSampleEvent.prepareForLaunch(current: anchor)
    try require(
        secondSampleEvents.values.count == 1
            && secondSampleEvents.values[0].generation == foreign
            && immutableSessionAnchor.failureReason == .anchorChangedBeforeLaunch
            && omittedBetweenSampleEvent.failureReason == nil,
        "a post-commit foreign activation must fail sample two solely from the continuous event record even after A is frontmost again"
    )

    var silentFrontmostChange = ForegroundTransitionState(anchor: anchor)
    silentFrontmostChange.prepareForLaunch(current: foreign)
    var perSampleRecaptureWouldAccept = ForegroundTransitionState(anchor: foreign)
    perSampleRecaptureWouldAccept.prepareForLaunch(current: foreign)
    try require(
        silentFrontmostChange.failureReason == .anchorChangedBeforeLaunch
            && perSampleRecaptureWouldAccept.failureReason == nil,
        "sample two must reject silent frontmost B where recapturing B per sample would pass"
    )
    try require(
        sessionCursor.end(secondLease),
        "the second sample lease must be explicitly releasable"
    )

    var racingCursor = ForegroundSessionCursorState(
        anchor: anchor,
        committedCursor: 0
    )
    guard let racingLease = racingCursor.beginSample() else {
        throw HarnessError.measurement("self-test failed: racing foreground lease was unavailable")
    }
    let racingRecorder = ForegroundActivationRecorder()
    let racingAnchorIntent = try beginTestObservation(racingRecorder)
    racingRecorder.completeObservation(racingAnchorIntent.id, generation: anchor)
    let candidateSnapshot = racingRecorder.restorationSnapshot(after: 0)
    let racingForeignIntent = try beginTestObservation(racingRecorder)
    let candidateStayedCurrent = racingRecorder.restorationSnapshotIsCurrent(candidateSnapshot)
    if candidateStayedCurrent {
        _ = racingCursor.commit(racingLease, cursor: candidateSnapshot.nextIndex)
    }
    try require(
        !candidateStayedCurrent
            && racingCursor.committedCursor == 0
            && racingCursor.activeLease == racingLease,
        "an activation beginning after the candidate snapshot must prevent its cursor from committing"
    )
    racingRecorder.completeObservation(racingForeignIntent.id, generation: foreign)
    try require(
        racingCursor.end(racingLease),
        "a failed racing restoration must retain ownership until explicit sample finish"
    )

    var rejectedCommitRestoration = ForegroundTransitionState(anchor: anchor)
    let rejectedCommitAccepted = rejectedCommitRestoration.observeCommittedAnchorRestoration(
        current: anchor,
        anchorStatus: .sameGeneration,
        sessionCommitAccepted: false
    )
    var acceptedCommitRestoration = ForegroundTransitionState(anchor: anchor)
    let acceptedCommit = acceptedCommitRestoration.observeCommittedAnchorRestoration(
        current: anchor,
        anchorStatus: .sameGeneration,
        sessionCommitAccepted: true
    )
    try require(
        !rejectedCommitAccepted
            && !rejectedCommitRestoration.exactAnchorRestoredAfterCleanup
            && rejectedCommitRestoration.failureReason == .sessionContinuityUnavailable
            && acceptedCommit
            && acceptedCommitRestoration.exactAnchorRestoredAfterCleanup
            && acceptedCommitRestoration.failureReason == nil
            && abortedReasonAfterForegroundSessionFinalization(
                existingAbortedReason: nil,
                foregroundSessionProofComplete: false
            ) == "foreground_session_continuity_unproven"
            && abortedReasonAfterForegroundSessionFinalization(
                existingAbortedReason: "primary_failure",
                foregroundSessionProofComplete: false
            ) == "primary_failure"
            && !benchmarkMeasurementSucceeded(
                abortedReason: nil,
                foregroundSessionProofComplete: false,
                samplesContainFailure: false
            )
            && benchmarkMeasurementSucceeded(
                abortedReason: nil,
                foregroundSessionProofComplete: true,
                samplesContainFailure: false
            ),
        "a rejected session cursor commit must fail typed before exact restoration and must fail the run without masking an earlier reason"
    )

    let foreignTailRecorder = ForegroundActivationRecorder()
    let foreignTailIntent = try beginTestObservation(foreignTailRecorder)
    foreignTailRecorder.completeObservation(foreignTailIntent.id, generation: foreign)
    let foreignTailSnapshot = foreignTailRecorder.restorationSnapshot(after: 0)
    try require(
        !foregroundTailCanSeal(
            anchor: anchor,
            events: foreignTailSnapshot.values,
            hasIncompleteObservation: foreignTailSnapshot.hasIncompleteObservation,
            anchorStatus: .sameGeneration,
            frontmost: anchor
        ),
        "a foreign tail intent must fail even when A is frontmost again"
    )

    let reboundTailRecorder = ForegroundActivationRecorder()
    let reboundTailForeign = try beginTestObservation(reboundTailRecorder)
    reboundTailRecorder.completeObservation(reboundTailForeign.id, generation: foreign)
    let reboundTailAnchor = try beginTestObservation(reboundTailRecorder)
    reboundTailRecorder.completeObservation(reboundTailAnchor.id, generation: anchor)
    let reboundTailSnapshot = reboundTailRecorder.restorationSnapshot(after: 0)
    try require(
        !foregroundTailCanSeal(
            anchor: anchor,
            events: reboundTailSnapshot.values,
            hasIncompleteObservation: reboundTailSnapshot.hasIncompleteObservation,
            anchorStatus: .sameGeneration,
            frontmost: anchor
        ),
        "a foreign-to-anchor tail rebound must not erase the foreign activation"
    )

    let pendingTailRecorder = ForegroundActivationRecorder()
    let pendingTailIntent = try beginTestObservation(pendingTailRecorder)
    let pendingTailSnapshot = pendingTailRecorder.restorationSnapshot(after: 0)
    try require(
        !foregroundTailCanSeal(
            anchor: anchor,
            events: pendingTailSnapshot.values,
            hasIncompleteObservation: pendingTailSnapshot.hasIncompleteObservation,
            anchorStatus: .sameGeneration,
            frontmost: anchor
        ),
        "an incomplete final activation slot must fail the tail seal closed"
    )
    pendingTailRecorder.completeObservation(pendingTailIntent.id, generation: anchor)

    let unavailableTailRecorder = ForegroundActivationRecorder()
    let unavailableTailIntent = try beginTestObservation(unavailableTailRecorder)
    unavailableTailRecorder.completeObservation(unavailableTailIntent.id, generation: nil)
    let unavailableTailSnapshot = unavailableTailRecorder.restorationSnapshot(after: 0)
    try require(
        !foregroundTailCanSeal(
            anchor: anchor,
            events: unavailableTailSnapshot.values,
            hasIncompleteObservation: unavailableTailSnapshot.hasIncompleteObservation,
            anchorStatus: .sameGeneration,
            frontmost: anchor
        ),
        "a completed tail activation without generation proof must fail closed"
    )

    try require(
        !foregroundTailCanSeal(
            anchor: anchor,
            events: [],
            hasIncompleteObservation: false,
            anchorStatus: .sameGeneration,
            frontmost: foreign
        )
            && !foregroundTailCanSeal(
                anchor: anchor,
                events: [],
                hasIncompleteObservation: false,
                anchorStatus: .reused,
                frontmost: anchor
            ),
        "silent frontmost B and a reused anchor generation must each fail the final tail seal"
    )

    let staleTailRecorder = ForegroundActivationRecorder()
    let staleTailSnapshot = staleTailRecorder.restorationSnapshot(after: 0)
    let staleTailEvent = try beginTestObservation(staleTailRecorder)
    staleTailRecorder.completeObservation(staleTailEvent.id, generation: anchor)
    let staleTailAccepted = staleTailRecorder.sealCurrentSnapshot(
        staleTailSnapshot,
        acceptance: { true }
    )
    try require(
        !staleTailAccepted,
        "a stale final snapshot must not close or seal the foreground recorder"
    )

#if FOREGROUND_STATE_SELF_TEST
    let admissionBarrier = ForegroundObservationAdmissionBarrier()
    let contendedRecorder = ForegroundActivationRecorder(
        testAdmissionBarrier: admissionBarrier,
        testObservationSeedProvider: { recorderLockHeld in
            admissionBarrier.supplyObservationSeedWhileRecorderLockShouldBeOwned(
                recorderLockHeld: recorderLockHeld
            )
        }
    )
    let snapshotBeforeContendedBegin = contendedRecorder.restorationSnapshot(after: 0)
    let contendedBeginFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        _ = contendedRecorder.beginObservation()
        contendedBeginFinished.signal()
    }
    guard admissionBarrier.awaitAdmissionWorkStarting() else {
        throw HarnessError.measurement(
            "self-test failed: contended callback did not start admission work"
        )
    }
    let contendedSealAccepted = contendedRecorder.sealCurrentSnapshot(
        snapshotBeforeContendedBegin,
        acceptance: { true }
    )
    guard contendedBeginFinished.wait(timeout: .now() + 2) == .success else {
        throw HarnessError.measurement(
            "self-test failed: contended callback did not finish slot admission"
        )
    }
    let snapshotAfterContendedBegin = contendedRecorder.restorationSnapshot(after: 0)
    try require(
        !contendedSealAccepted
            && admissionBarrier.observedRecorderLockHeldDuringAdmissionWork()
            && snapshotAfterContendedBegin.revision
                > snapshotBeforeContendedBegin.revision
            && snapshotAfterContendedBegin.slotCount == 1
            && snapshotAfterContendedBegin.hasIncompleteObservation,
        "a callback owning the recorder lock must install its pending slot before a prior snapshot can seal"
    )
    contendedRecorder.stopAcceptingObservations()
#endif

    let cleanTailRecorder = ForegroundActivationRecorder()
    let cleanTailSnapshot = cleanTailRecorder.restorationSnapshot(after: 0)
    var cleanTailCursor = ForegroundSessionCursorState(
        anchor: anchor,
        committedCursor: 0
    )
    let cleanTailAccepted = cleanTailRecorder.sealCurrentSnapshot(
        cleanTailSnapshot,
        acceptance: {
            foregroundTailCanSeal(
                anchor: anchor,
                events: cleanTailSnapshot.values,
                hasIncompleteObservation: cleanTailSnapshot.hasIncompleteObservation,
                anchorStatus: .sameGeneration,
                frontmost: anchor
            ) && cleanTailCursor.sealTail(cursor: cleanTailSnapshot.nextIndex)
        }
    )
    let sealedRecorderSnapshot = cleanTailRecorder.restorationSnapshot(after: 0)
    let rejectedPostSealObservation = cleanTailRecorder.beginObservation()
    let unchangedSealedRecorderSnapshot = cleanTailRecorder.restorationSnapshot(after: 0)
    try require(
        cleanTailAccepted
            && rejectedPostSealObservation == nil
            && sealedRecorderSnapshot.revision == unchangedSealedRecorderSnapshot.revision
            && sealedRecorderSnapshot.slotCount == unchangedSealedRecorderSnapshot.slotCount,
        "successful tail sealing must atomically close observation without appending or revising later callbacks"
    )

    // Sensitivity control: this sequence differs from the accepted transition
    // by one target-to-anchor event. Removing that event must change the result.
    var rebound = ForegroundTransitionState(anchor: anchor)
    rebound.prepareForLaunch(current: anchor)
    rebound.bindTarget(target)
    rebound.observeActivation(target)
    rebound.observeActivation(anchor)
    rebound.acceptBeacon(targetReportsActive: false)
    try require(
        rebound.failureReason == .anchorReboundedBeforeBeacon
            && clean.failureReason == nil,
        "a target-to-anchor rebound before the beacon must make the clean control fail"
    )

    var deadAnchor = ForegroundTransitionState(anchor: anchor)
    deadAnchor.prepareForLaunch(current: anchor)
    deadAnchor.bindTarget(target)
    deadAnchor.observeActivation(target)
    deadAnchor.acceptBeacon(targetReportsActive: true)
    try require(
        !deadAnchor.observeAnchorRestoration(current: nil, anchorStatus: .exited)
            && deadAnchor.failureReason == .anchorExitedBeforeRestoration
            && deadAnchor.transitionUninterruptedBeforeBeacon,
        "an exited anchor generation must fail restoration without rewriting the clean pre-beacon fact"
    )

    let reusedAnchor = ForegroundProcessGeneration(
        pid: anchor.pid,
        uniqueId: anchor.uniqueId + 1,
        pidVersion: anchor.pidVersion + 1
    )
    var reused = ForegroundTransitionState(anchor: anchor)
    reused.prepareForLaunch(current: anchor)
    reused.bindTarget(target)
    reused.observeActivation(target)
    reused.acceptBeacon(targetReportsActive: true)
    try require(
        !reused.observeAnchorRestoration(current: reusedAnchor, anchorStatus: .reused)
            && reused.failureReason == .anchorGenerationChangedBeforeRestoration,
        "a reused anchor PID must not be mistaken for the captured generation"
    )

    var targetNeverActive = ForegroundTransitionState(anchor: anchor)
    targetNeverActive.prepareForLaunch(current: anchor)
    targetNeverActive.bindTarget(target)
    targetNeverActive.acceptBeacon(targetReportsActive: false)
    try require(
        targetNeverActive.failureReason == .targetNeverActive
            && !targetNeverActive.beaconAccepted,
        "a beacon cannot succeed when the target never became foreground"
    )

    var targetInactiveAtBeacon = ForegroundTransitionState(anchor: anchor)
    targetInactiveAtBeacon.prepareForLaunch(current: anchor)
    targetInactiveAtBeacon.bindTarget(target)
    targetInactiveAtBeacon.observeActivation(target)
    targetInactiveAtBeacon.acceptBeacon(targetReportsActive: false)
    try require(
        targetInactiveAtBeacon.failureReason == .targetNotActiveAtBeacon
            && targetInactiveAtBeacon.targetActivatedBeforeBeacon
            && !targetInactiveAtBeacon.beaconAccepted,
        "an activated target reporting inactive at the beacon must reach its distinct failure branch"
    )

    var restorationTimedOut = ForegroundTransitionState(anchor: anchor)
    restorationTimedOut.prepareForLaunch(current: anchor)
    restorationTimedOut.bindTarget(target)
    restorationTimedOut.observeActivation(target)
    restorationTimedOut.acceptBeacon(targetReportsActive: true)
    restorationTimedOut.restorationTimedOut()
    try require(
        restorationTimedOut.failureReason == .anchorNotRestoredBeforeDeadline
            && restorationTimedOut.transitionUninterruptedBeforeBeacon
            && !restorationTimedOut.exactAnchorRestoredAfterCleanup,
        "an unrestored anchor at the deadline must fail without rewriting clean pre-beacon proof"
    )

    let publicEvidence = ForegroundEvidence(
        observerInstalledBeforeLaunch: true,
        anchorGenerationCaptured: true,
        targetGenerationCaptured: true,
        targetActivatedBeforeBeacon: false,
        transitionUninterruptedBeforeBeacon: false,
        exactAnchorRestoredAfterCleanup: false,
        reasonCode: .targetNeverActive
    )
    let publicObject = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(publicEvidence)
    )
    guard let publicFields = publicObject as? [String: Any] else {
        throw HarnessError.measurement("self-test failed: foreground evidence was not an object")
    }
    try require(
        Set(publicFields.keys) == [
            "observerInstalledBeforeLaunch",
            "anchorGenerationCaptured",
            "targetGenerationCaptured",
            "targetActivatedBeforeBeacon",
            "transitionUninterruptedBeforeBeacon",
            "exactAnchorRestoredAfterCleanup",
            "reasonCode",
        ],
        "public foreground evidence must contain only stable booleans and one reason code"
    )
    try require(
        publicFields.allSatisfy { $0.value is Bool || $0.value is String },
        "public foreground evidence must never serialize application identities"
    )
    let completeSessionEvidence = ForegroundSessionEvidence(
        observerInstalledOnceBeforeArms: true,
        observerRemainedInstalledThroughArms: true,
        immutableAnchorUsedForEveryStartedSample: true,
        committedCursorAdvancedOnlyAfterExactRestoration: true,
        allSampleLeasesReleased: true,
        tailSealedAtExactAnchor: true,
        samplesStarted: 11,
        exactRestorationCommitCount: 11,
        finishedSampleCount: 11
    )
    let interruptedSessionEvidence = ForegroundSessionEvidence(
        observerInstalledOnceBeforeArms: true,
        observerRemainedInstalledThroughArms: false,
        immutableAnchorUsedForEveryStartedSample: true,
        committedCursorAdvancedOnlyAfterExactRestoration: true,
        allSampleLeasesReleased: true,
        tailSealedAtExactAnchor: true,
        samplesStarted: 11,
        exactRestorationCommitCount: 11,
        finishedSampleCount: 11
    )
    let emptySessionEvidence = ForegroundSessionEvidence(
        observerInstalledOnceBeforeArms: true,
        observerRemainedInstalledThroughArms: true,
        immutableAnchorUsedForEveryStartedSample: true,
        committedCursorAdvancedOnlyAfterExactRestoration: true,
        allSampleLeasesReleased: true,
        tailSealedAtExactAnchor: true,
        samplesStarted: 0,
        exactRestorationCommitCount: 0,
        finishedSampleCount: 0
    )
    let unsealedSessionEvidence = ForegroundSessionEvidence(
        observerInstalledOnceBeforeArms: true,
        observerRemainedInstalledThroughArms: true,
        immutableAnchorUsedForEveryStartedSample: true,
        committedCursorAdvancedOnlyAfterExactRestoration: true,
        allSampleLeasesReleased: true,
        tailSealedAtExactAnchor: false,
        samplesStarted: 11,
        exactRestorationCommitCount: 11,
        finishedSampleCount: 11
    )
    let sessionObject = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(completeSessionEvidence)
    )
    guard let sessionFields = sessionObject as? [String: Any] else {
        throw HarnessError.measurement("self-test failed: foreground session evidence was not an object")
    }
    try require(
        completeSessionEvidence.isCompleteForPublication(recordedSampleCount: 11)
            && !interruptedSessionEvidence.isCompleteForPublication(recordedSampleCount: 11)
            && !emptySessionEvidence.isCompleteForPublication(recordedSampleCount: 0)
            && !unsealedSessionEvidence.isCompleteForPublication(recordedSampleCount: 11)
            && Set(sessionFields.keys) == [
                "observerInstalledOnceBeforeArms",
                "observerRemainedInstalledThroughArms",
                "immutableAnchorUsedForEveryStartedSample",
                "committedCursorAdvancedOnlyAfterExactRestoration",
                "allSampleLeasesReleased",
                "tailSealedAtExactAnchor",
                "atLeastOneSampleStarted",
                "exactRestorationCommittedForEveryStartedSample",
                "everyStartedSampleFinished",
                "startedSampleCount",
                "exactRestorationCount",
                "finishedSampleCount",
            ]
            && sessionFields.values.allSatisfy { $0 is Bool || $0 is Int }
            && sessionFields["startedSampleCount"] as? Int == 11
            && sessionFields["exactRestorationCount"] as? Int == 11
            && sessionFields["finishedSampleCount"] as? Int == 11,
        "session proof must be explicit, count-bound, falsifiable, and identity-free"
    )
    let completeForegroundEvidence = ForegroundEvidence(
        observerInstalledBeforeLaunch: true,
        anchorGenerationCaptured: true,
        targetGenerationCaptured: true,
        targetActivatedBeforeBeacon: true,
        transitionUninterruptedBeforeBeacon: true,
        exactAnchorRestoredAfterCleanup: true,
        reasonCode: nil
    )
    let reasonlessIncompleteForegroundEvidence = ForegroundEvidence(
        observerInstalledBeforeLaunch: true,
        anchorGenerationCaptured: true,
        targetGenerationCaptured: true,
        targetActivatedBeforeBeacon: true,
        transitionUninterruptedBeforeBeacon: true,
        exactAnchorRestoredAfterCleanup: false,
        reasonCode: nil
    )
    try require(
        completeForegroundEvidence.isCompleteForPublication
            && !ForegroundEvidence.notAttempted.isCompleteForPublication
            && !reasonlessIncompleteForegroundEvidence.isCompleteForPublication,
        "the single foreground completeness predicate must reject not-attempted and incomplete proof"
    )
    try require(
        sampleErrorAfterForegroundFinalization(
            existingSampleError: nil,
            foregroundEvidence: completeForegroundEvidence
        ) == nil
            && sampleErrorAfterForegroundFinalization(
                existingSampleError: nil,
                foregroundEvidence: ForegroundEvidence.notAttempted
            ) == "foreground_interference"
            && sampleErrorAfterForegroundFinalization(
                existingSampleError: "timeout",
                foregroundEvidence: reasonlessIncompleteForegroundEvidence
            ) == "timeout",
        "sample finalization must reject incomplete foreground proof without overwriting a primary error"
    )
    try require(
        sampleErrorAfterForegroundRestoration(
            existingSampleError: "timeout",
            foregroundFailureReason: .anchorNotRestoredBeforeDeadline
        ) == "timeout",
        "anchor restoration failure must preserve an earlier primary sample error"
    )
    try require(
        sampleErrorAfterForegroundRestoration(
            existingSampleError: nil,
            foregroundFailureReason: .anchorNotRestoredBeforeDeadline
        ) == "foreground_interference",
        "anchor restoration failure must become primary when no earlier sample error exists"
    )
}

private func validateForegroundPublicationPolicyContract() throws {
    let cleanRepository = RepositoryMetadata(
        identifier: canonicalBenchesRepositoryIdentifier,
        commit: String(repeating: "a", count: 40),
        workingTreeState: .clean,
        commitAdvertisedAsOriginHead: true
    )
    let nominalHost = HostMetadata(
        operatingSystemVersion: "test",
        architecture: "arm64",
        hardwareModel: "test",
        processor: "test",
        logicalCpuCount: 1,
        physicalMemoryBytes: 1,
        lowPowerModeEnabled: false,
        thermalState: "nominal"
    )
    let completeForegroundEvidence = ForegroundEvidence(
        observerInstalledBeforeLaunch: true,
        anchorGenerationCaptured: true,
        targetGenerationCaptured: true,
        targetActivatedBeforeBeacon: true,
        transitionUninterruptedBeforeBeacon: true,
        exactAnchorRestoredAfterCleanup: true,
        reasonCode: nil
    )
    let incompleteForegroundEvidence = ForegroundEvidence(
        observerInstalledBeforeLaunch: true,
        anchorGenerationCaptured: true,
        targetGenerationCaptured: true,
        targetActivatedBeforeBeacon: true,
        transitionUninterruptedBeforeBeacon: true,
        exactAnchorRestoredAfterCleanup: false,
        reasonCode: nil
    )
    let completeControls = Array(repeating: completeForegroundEvidence, count: 11)
    let notAttemptedControls = Array(
        repeating: completeForegroundEvidence,
        count: 10
    ) + [ForegroundEvidence.notAttempted]
    let incompleteControls = Array(
        repeating: completeForegroundEvidence,
        count: 10
    ) + [incompleteForegroundEvidence]

    func completeCount(_ evidence: [ForegroundEvidence]) -> Int {
        evidence.filter(\.isCompleteForPublication).count
    }

    func assessment(
        completeForegroundCount: Int,
        foregroundSessionProofComplete: Bool = true,
        recordedSampleCount: Int = 11,
        foregroundSessionStartedSampleCount: Int = 11,
        foregroundSessionExactRestorationCount: Int = 11,
        foregroundSessionFinishedSampleCount: Int = 11
    ) -> PublicationMetadata {
        let arm = PublicationArmFacts(
            label: "fixture",
            sampleCount: 11,
            successfulSampleCount: 11,
            completeCleanupCount: 11,
            completeMetricCount: 11,
            completeForegroundCount: completeForegroundCount,
            fixtureUnchanged: true,
            provenanceComplete: true,
            adapterRecipeMatches: true,
            toolchainComplete: true,
            publicArgumentsSafe: true,
            sampleHostConditionsAcceptable: true
        )
        return publicationAssessment(
            requested: true,
            facts: PublicationFacts(
                runsPerApp: 11,
                stableCoalitionObservations: 3,
                stableCoalitionWindowMilliseconds: 500,
                rssToleranceKiB: 1_024,
                repositoryBefore: cleanRepository,
                repositoryAfter: cleanRepository,
                harnessProvenanceComplete: true,
                canonicalHTML: true,
                publicationOutputProvided: true,
                outputWillPreserveCleanTree: true,
                hostBefore: nominalHost,
                hostAfter: nominalHost,
                aborted: false,
                foregroundSessionProofComplete: foregroundSessionProofComplete,
                recordedSampleCount: recordedSampleCount,
                foregroundSessionStartedSampleCount: foregroundSessionStartedSampleCount,
                foregroundSessionExactRestorationCount: foregroundSessionExactRestorationCount,
                foregroundSessionFinishedSampleCount: foregroundSessionFinishedSampleCount,
                arms: [arm]
            )
        )
    }

    let completeAssessment = assessment(
        completeForegroundCount: completeCount(completeControls)
    )
    try require(
        completeAssessment.eligible && completeAssessment.policyVersion == 4,
        "11-of-11 foreground proof must pass publication policy v4"
    )

    let notAttemptedCompleteCount = completeCount(notAttemptedControls)
    let incompleteCompleteCount = completeCount(incompleteControls)
    let notAttemptedAssessment = assessment(
        completeForegroundCount: notAttemptedCompleteCount
    )
    let incompleteAssessment = assessment(
        completeForegroundCount: incompleteCompleteCount
    )
    try require(
        notAttemptedCompleteCount == 10
            && incompleteCompleteCount == 10
            && !notAttemptedAssessment.eligible
            && !incompleteAssessment.eligible
            && notAttemptedAssessment.reasons.contains {
                $0.code == "foreground_proof_missing" && $0.label == "fixture"
            }
            && incompleteAssessment.reasons.contains {
                $0.code == "foreground_proof_missing" && $0.label == "fixture"
            },
        "not-attempted and incomplete 10-of-11 foreground proof must fail with the stable labeled reason"
    )
    let missingSessionAssessment = assessment(
        completeForegroundCount: completeCount(completeControls),
        foregroundSessionProofComplete: false
    )
    try require(
        !missingSessionAssessment.eligible
            && missingSessionAssessment.reasons.contains {
                $0.code == "foreground_session_proof_missing" && $0.label == nil
            },
        "publication policy must reject missing continuous session proof with its stable reason"
    )

    let startedCountNMinusOne = assessment(
        completeForegroundCount: completeCount(completeControls),
        foregroundSessionStartedSampleCount: 10
    )
    let restorationCountNMinusOne = assessment(
        completeForegroundCount: completeCount(completeControls),
        foregroundSessionExactRestorationCount: 10
    )
    let finishedCountNMinusOne = assessment(
        completeForegroundCount: completeCount(completeControls),
        foregroundSessionFinishedSampleCount: 10
    )
    let countMismatchAssessments = [
        startedCountNMinusOne,
        restorationCountNMinusOne,
        finishedCountNMinusOne,
    ]
    try require(
        countMismatchAssessments.allSatisfy { assessment in
            !assessment.eligible
                && assessment.reasons.contains {
                    $0.code == "foreground_session_proof_missing" && $0.label == nil
                }
            },
        "each session lifecycle count must independently bind eleven emitted sample records"
    )
}

private func validatePublicEvidenceRedaction() throws {
    let rawToken = "raw-token-public-evidence-negative-control"
    let rawAbsolutePath = "/private/tmp/keld-public-evidence-negative-control/secret.app"
    let rawPeerAddress = "127.0.0.1:61991"
    let rawStartIdentity = "raw-start-identity-public-evidence-negative-control"
    let rawCoalitionName = "application.raw-coalition-name-public-evidence-negative-control"
    let rawPid: Int32 = 2_000_000_011
    let rawParentPid: Int32 = 2_000_000_033
    let rawUniqueId: UInt64 = 18_000_000_000_000_071
    let rawCoalitionId: UInt64 = 18_000_000_000_000_133
    let rawTasksStarted: UInt64 = 18_000_000_000_000_177
    let rawTasksExited: UInt64 = 18_000_000_000_000_199
    let rawT0: UInt64 = 18_000_000_000_000_211
    let rawObserved: UInt64 = rawT0 + 81_000_000
    let context = PublicEvidenceContext(
        t0MonotonicNanoseconds: rawT0,
        salt: "public-evidence-self-test-run-a"
    )
    let secondRunContext = PublicEvidenceContext(
        t0MonotonicNanoseconds: rawT0,
        salt: "public-evidence-self-test-run-b"
    )
    let stableIdentity = StableProcessIdentity(
        pid: rawPid,
        parentPid: rawParentPid,
        startIdentity: rawStartIdentity,
        uniqueId: rawUniqueId,
        commandSha256: sha256Hex(Data(rawAbsolutePath.utf8))
    )
    let process = ProcessMeasurement(
        pid: rawPid,
        parentPid: rawParentPid,
        startIdentity: rawStartIdentity,
        uniqueId: rawUniqueId,
        rssKiB: 12_345,
        classification: "host",
        commandSha256: sha256Hex(Data(rawAbsolutePath.utf8))
    )
    let snapshot = CoalitionSnapshot(
        identity: CoalitionIdentity(
            id: rawCoalitionId,
            name: rawCoalitionName,
            bundleIdentifier: "com.example.PublicEvidenceProbe",
            activeCount: 1
        ),
        lifecycleCounters: CoalitionLifecycleCounters(
            tasksStarted: rawTasksStarted,
            tasksExited: rawTasksExited
        ),
        processes: [process],
        rssByClassificationKiB: ["host": 12_345],
        totalRssKiB: 12_345,
        observedMonotonicNanoseconds: rawObserved
    )
    let receipt = BeaconReceipt(
        token: rawToken,
        receivedMonotonicNanoseconds: rawT0 + 42_000_000,
        clientNowMilliseconds: 42,
        scriptStartMilliseconds: 1,
        firstRafMilliseconds: 20,
        secondRafMilliseconds: 40,
        documentVisibilityState: "visible",
        documentHadFocus: true,
        peerAddress: rawPeerAddress
    )
    let event = ServerEvent(
        monotonicNanoseconds: rawT0 + 10_000_000,
        requestTarget: "/run/\(rawToken)/hello.html?source=\(rawAbsolutePath)",
        kind: "html",
        status: 200,
        accepted: true,
        reason: "canonical document served",
        presentedToken: rawToken
    )
    let stableEvidence = StableProcessEvidence(stableIdentity, context: context)
    let processEvidence = ProcessMeasurementEvidence(process, context: context)
    let coalitionEvidence = CoalitionEvidence(snapshot, context: context)

    try require(
        stableEvidence.processPseudonym == processEvidence.processPseudonym,
        "the same process must have one pseudonym throughout a sample"
    )
    try require(
        stableEvidence.parentProcessPseudonym == processEvidence.parentProcessPseudonym,
        "the same parent process must have one pseudonym throughout a sample"
    )
    try require(
        stableEvidence.processPseudonym
            != secondRunContext.processPseudonym(rawPid),
        "process pseudonyms must be salted independently for every sample"
    )
    try require(
        coalitionEvidence.identity.coalitionPseudonym
            == context.coalitionPseudonym(rawCoalitionId),
        "the same coalition must have one pseudonym throughout a sample"
    )
    try require(
        coalitionEvidence.identity.coalitionPseudonym
            != secondRunContext.coalitionPseudonym(rawCoalitionId),
        "coalition pseudonyms must be salted independently for every sample"
    )
    try require(
        coalitionEvidence.observedOffsetMilliseconds == 81,
        "coalition timestamps must be encoded relative to sample t0"
    )

    let sample = SampleRecord(
        globalOrdinal: 1,
        round: 1,
        appOrdinal: 1,
        label: "public-evidence-probe",
        status: "ok",
        error: nil,
        launchedProcessIdentity: stableEvidence,
        launchServicesASNResolved: true,
        launchServicesOriginalPidPresent: true,
        originalPidMatchesReturnedPidCoalition: true,
        launchCallbackOffsetMilliseconds: context.offsetMilliseconds(for: rawT0 + 5_000_000),
        applicationWasActiveAtLaunchCallback: true,
        applicationWasActiveAtBeacon: true,
        foreground: ForegroundEvidence(
            observerInstalledBeforeLaunch: true,
            anchorGenerationCaptured: true,
            targetGenerationCaptured: true,
            targetActivatedBeforeBeacon: true,
            transitionUninterruptedBeforeBeacon: true,
            exactAnchorRestoredAfterCleanup: true,
            reasonCode: nil
        ),
        hostConditionBeforeLaunch: HostConditionEvidence(
            lowPowerModeEnabled: false,
            thermalState: "nominal"
        ),
        hostConditionAfterCleanup: HostConditionEvidence(
            lowPowerModeEnabled: false,
            thermalState: "nominal"
        ),
        beacon: BeaconEvidence(receipt, context: context),
        doubleRafPaintOpportunityProxyMilliseconds: 42,
        startupTrace: nil,
        stableCoalitionObservations: 3,
        coalition: coalitionEvidence,
        serverEvents: [ServerEventEvidence(event, context: context)],
        cleanup: CleanupRecord(
            gracefulTerminateAccepted: true,
            coalitionHardKillInvoked: false,
            applicationTerminated: true,
            coalitionDrained: true,
            error: nil
        )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encodedSample = String(decoding: try encoder.encode(sample), as: UTF8.self)
    let encodedProtocol = String(decoding: try encoder.encode(ProtocolMetadata(
        listener: "127.0.0.1:ephemeral",
        htmlFileName: "hello.html",
        htmlSha256: String(repeating: "a", count: 64),
        tokenTransports: ["URL path/query"],
        completionSignal: "double-rAF paint-opportunity proxy",
        launchApi: "NSWorkspace.openApplication",
        coalitionApi: "resource coalition"
    )), as: UTF8.self)
    let encodedEvidence = encodedSample + encodedProtocol
    let forbiddenRawValues = [
        rawToken,
        sha256Hex(Data(rawToken.utf8)),
        rawAbsolutePath,
        rawPeerAddress,
        rawStartIdentity,
        rawCoalitionName,
        String(rawPid),
        String(rawParentPid),
        String(rawUniqueId),
        String(rawCoalitionId),
        String(rawTasksStarted),
        String(rawTasksExited),
        String(rawT0),
        String(rawObserved),
        "127.0.0.1:61991",
    ]
    for rawValue in forbiddenRawValues {
        try require(
            !encodedEvidence.contains(rawValue),
            "public evidence must omit raw value \(rawValue)"
        )
    }
    let forbiddenRawKeys = [
        "\"tokenSha256\"",
        "\"pid\"",
        "\"parentPid\"",
        "\"startIdentity\"",
        "\"uniqueId\"",
        "\"lifecycleCounters\"",
        "\"tasksStarted\"",
        "\"tasksExited\"",
        "\"peerAddress\"",
        "\"t0MonotonicNanoseconds\"",
        "\"launchCallbackMonotonicNanoseconds\"",
        "\"receivedMonotonicNanoseconds\"",
        "\"observedMonotonicNanoseconds\"",
        "\"monotonicNanoseconds\"",
    ]
    for rawKey in forbiddenRawKeys {
        try require(
            !encodedEvidence.contains(rawKey),
            "public evidence must omit raw key \(rawKey)"
        )
    }
    try require(
        encodedProtocol.contains("127.0.0.1:ephemeral"),
        "protocol evidence must describe the listener without publishing its port"
    )
}

private func buildStubbornCleanupSelfTestApp(temporaryRoot: URL) throws -> URL {
    let executableParent = try loadedExecutableURL().deletingLastPathComponent()
    let rootResult = try runCommand(
        "/usr/bin/git",
        ["-C", executableParent.path, "rev-parse", "--show-toplevel"]
    )
    guard rootResult.status == 0 else {
        throw HarnessError.measurement("self-test requires the harness executable to remain inside its source repository")
    }
    let repositoryRoot = URL(
        fileURLWithPath: rootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
        isDirectory: true
    )
    let fixtureRoot = repositoryRoot
        .appendingPathComponent("macos/harness/test-fixtures/stubborn", isDirectory: true)
    let source = fixtureRoot.appendingPathComponent("main.swift")
    let plist = fixtureRoot.appendingPathComponent("Info.plist")
    guard FileManager.default.fileExists(atPath: source.path),
          FileManager.default.fileExists(atPath: plist.path) else {
        throw HarnessError.measurement("self-test stubborn cleanup fixture is missing")
    }

    let app = temporaryRoot.appendingPathComponent("Stubborn Probe.app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let executable = macOS.appendingPathComponent("StubbornProbe")
    let compile = try runCommand(
        "/usr/bin/xcrun",
        [
            "swiftc", "-O",
            "-framework", "AppKit",
            "-framework", "WebKit",
            "-o", executable.path,
            source.path,
        ],
        timeoutSeconds: 60
    )
    guard compile.status == 0 else {
        throw HarnessError.measurement("self-test stubborn cleanup fixture did not compile")
    }
    try FileManager.default.copyItem(
        at: plist,
        to: contents.appendingPathComponent("Info.plist")
    )
    let signing = try runCommand(
        "/usr/bin/codesign",
        ["--force", "--sign", "-", app.path]
    )
    guard signing.status == 0 else {
        throw HarnessError.measurement("self-test stubborn cleanup fixture could not be ad-hoc signed")
    }
    return app
}

private func validateKernelGenerationSignalContract() throws {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/bin/sleep")
    probe.arguments = ["30"]
    try probe.run()
    defer {
        if probe.isRunning {
            probe.terminate()
            probe.waitUntilExit()
        }
    }
    guard let identity = try kernelProcessUniqueIdentity(for: probe.processIdentifier) else {
        throw HarnessError.measurement("process-generation ABI probe identity was unavailable")
    }
    let staleIdentity = KernelProcessUniqueIdentity(
        uniqueId: identity.uniqueId,
        pidVersion: identity.pidVersion &+ 1
    )
    guard try !signalProcessGeneration(
        pid: probe.processIdentifier,
        identity: staleIdentity,
        signal: SIGKILL
    ), probe.isRunning else {
        throw HarnessError.measurement("stale process generation unexpectedly accepted a signal")
    }
    guard try signalProcessGeneration(
        pid: probe.processIdentifier,
        identity: identity,
        signal: SIGKILL
    ) else {
        throw HarnessError.measurement("exact process generation did not accept a signal")
    }
    probe.waitUntilExit()
    guard !probe.isRunning,
          try kernelProcessUniqueIdentity(for: probe.processIdentifier) != identity else {
        throw HarnessError.measurement("process-generation ABI probe did not terminate")
    }
}

@MainActor
private func validateStubbornCleanupContract(
    appURL: URL,
    server: LoopbackBeaconServer,
    reader: ResourceCoalitionReader,
    injectFailureAfterChildCapture: Bool
) async throws {
    let spec = AppSpec(
        label: "Stubborn cleanup probe",
        bundleURL: appURL,
        bundleFileIdentity: try fileIdentity(at: appURL),
        argumentTemplates: [],
        buildCommand: "self-test fixture",
        startupTraceEnvironmentVariable: nil
    )
    let token = UUID().uuidString.lowercased()
    let foregroundSession = try ForegroundSessionMonitor.capture()
    defer { foregroundSession.stop() }
    let foregroundMonitor = try foregroundSession.beginSample()
    defer { foregroundMonitor.finish() }
    try server.activate(token: token)

    let outcome: LaunchOutcome
    do {
        outcome = try await launch(
            app: spec,
            benchmarkURL: server.url(for: token),
            token: token,
            measurementTimeoutNanoseconds: 10_000_000_000,
            foregroundMonitor: foregroundMonitor,
            startupTrace: nil
        )
    } catch {
        server.finish(token: token)
        do {
            try await server.quiesceClientHandlers(
                deadlineNanoseconds: monotonicNowNanoseconds() + 2_000_000_000
            )
        } catch let quiescenceError {
            writeDiagnostic("stubborn self-test launch failed and client quiescence also failed: \(quiescenceError)")
        }
        throw error
    }

    var ownership = outcome.kernelOwnership
    var preparationError: Error?
    if ownership == nil {
        do {
            ownership = try kernelLaunchOwnership(for: outcome.launchedPid)
        } catch {
            preparationError = error
        }
    }
    var cleanupIdentity: StableProcessIdentity?
    var coalitionId = ownership?.resourceCoalitionId
    var spawnedChild: (pid: Int32, identity: KernelProcessUniqueIdentity)?
    var injectedFailureObserved = false
    let injectedFailureMessage = "injected stubborn cleanup preparation failure"
    if let ownership {
        cleanupIdentity = StableProcessIdentity(
            pid: ownership.pid,
            parentPid: 0,
            startIdentity: "unavailable-at-launch-callback",
            uniqueId: ownership.uniqueId,
            commandSha256: nil
        )
        do {
            let observedIdentity = try reader.processIdentity(for: outcome.launchedPid)
            let observedCoalition = try reader.identity(for: outcome.launchedPid)
            try require(
                observedIdentity.uniqueId == ownership.uniqueId
                    && observedCoalition.id == ownership.resourceCoalitionId,
                "stubborn cleanup fixture must retain its callback process generation and coalition"
            )
            cleanupIdentity = observedIdentity
            coalitionId = observedCoalition.id

            let childDeadline = monotonicNowNanoseconds() + 5_000_000_000
            while spawnedChild == nil, monotonicNowNanoseconds() < childDeadline {
                let members = try reader.coalitionMemberPids(id: observedCoalition.id)
                for memberPid in members where memberPid != outcome.launchedPid {
                    let command = try runCommand(
                        "/bin/ps",
                        ["-p", String(memberPid), "-o", "command="]
                    )
                    guard command.status == 0,
                          command.stdout.contains("/bin/sleep 120"),
                          let childIdentity = try kernelProcessUniqueIdentity(for: memberPid) else {
                        continue
                    }
                    spawnedChild = (memberPid, childIdentity)
                    break
                }
                if spawnedChild == nil { await nextObservationTick(nanoseconds: 10_000_000) }
            }
            try require(
                spawnedChild != nil,
                "self-test failed: stubborn fixture did not spawn its expected child"
            )
            if injectFailureAfterChildCapture {
                throw HarnessError.measurement(injectedFailureMessage)
            }
        } catch {
            if case HarnessError.measurement(let message) = error,
               message == injectedFailureMessage {
                injectedFailureObserved = true
            }
            preparationError = error
        }
    } else if preparationError == nil {
        preparationError = HarnessError.measurement(
            "self-test failed: stubborn fixture launch ownership was unavailable"
        )
    }

    let cleanupRecord: CleanupRecord
    if let cleanupIdentity, let coalitionId {
        cleanupRecord = await cleanup(
            application: outcome.application,
            launchedProcessIdentity: cleanupIdentity,
            expectedBundleFileIdentity: spec.bundleFileIdentity,
            knownCoalitionId: coalitionId,
            reader: reader,
            timeoutNanoseconds: 3_000_000_000
        )
    } else {
        let forceTerminateAccepted = outcome.application.forceTerminate()
        writeDiagnostic(
            "self-test launch ownership unresolved; exact coalition containment could not be proven and manual remediation may be required"
        )
        cleanupRecord = CleanupRecord(
            gracefulTerminateAccepted: forceTerminateAccepted,
            coalitionHardKillInvoked: false,
            applicationTerminated: false,
            coalitionDrained: false,
            error: "launch_ownership_unresolved"
        )
    }
    await foregroundMonitor.awaitAnchorRestoration(
        deadlineNanoseconds: monotonicNowNanoseconds() + 3_000_000_000
    )
    let foregroundEvidence = foregroundMonitor.evidence
    foregroundMonitor.finish()
    let foregroundSessionEvidence = foregroundSession.finishArms()
    foregroundSession.stop()
    server.finish(token: token)
    var quiescenceError: Error?
    do {
        try await server.quiesceClientHandlers(
            deadlineNanoseconds: monotonicNowNanoseconds() + 2_000_000_000
        )
    } catch {
        quiescenceError = error
    }

    var containmentFailures: [String] = []
    if quiescenceError != nil { containmentFailures.append("client_handlers_unfinished") }
    if !cleanupRecord.gracefulTerminateAccepted {
        containmentFailures.append("graceful_termination_not_accepted")
    }
    if !cleanupRecord.coalitionHardKillInvoked {
        containmentFailures.append("hard_coalition_cleanup_not_invoked")
    }
    if !cleanupRecord.applicationTerminated {
        containmentFailures.append("application_generation_not_terminated")
    }
    if cleanupRecord.coalitionDrained != true {
        containmentFailures.append("coalition_not_drained")
    }
    if cleanupRecord.error != nil { containmentFailures.append("cleanup_error") }
    if !foregroundEvidence.exactAnchorRestoredAfterCleanup {
        containmentFailures.append(
            foregroundEvidence.reasonCode?.rawValue ?? "foreground_anchor_restoration_unproven"
        )
    }
    if !foregroundSessionEvidence.isCompleteForPublication(recordedSampleCount: 1) {
        containmentFailures.append("foreground_session_continuity_unproven")
    }
    if let spawnedChild {
        do {
            if try kernelProcessUniqueIdentity(for: spawnedChild.pid) == spawnedChild.identity {
                containmentFailures.append("exact_child_generation_survived")
            }
        } catch {
            containmentFailures.append("exact_child_generation_unverifiable")
        }
    }
    if !containmentFailures.isEmpty {
        if let preparationError {
            writeDiagnostic("stubborn self-test preparation also failed: \(preparationError)")
        }
        throw HarnessError.measurement(
            "stubborn self-test containment proof failed: \(containmentFailures.joined(separator: ","))"
        )
    }
    if let preparationError, !injectedFailureObserved { throw preparationError }
    try require(
        injectedFailureObserved == injectFailureAfterChildCapture,
        "stubborn cleanup negative control must reach the injected exceptional path"
    )
    try require(
        spawnedChild != nil,
        "self-test failed: stubborn child identity was not retained"
    )
    try require(
        cleanupRecord.gracefulTerminateAccepted
            && cleanupRecord.coalitionHardKillInvoked,
        "stubborn cleanup fixture must exercise hard coalition cleanup"
    )
    try require(
        !hasUnresolvedLaunchOwnership([cleanupRecord]),
        "proven cleanup must not trigger output quarantine"
    )
}

/// KEL-64 AC2: a wrong nonce, duplicate stage, omitted stage, or non-monotonic
/// timestamp must be a typed startup-trace measurement failure. Each negative
/// mutates the accepted AC1 recorder record; accepting that defect fails the test.
private func validateStartupTraceRejectionContract() throws {
    let token = "launch-nonce-ac1"
    let accepted = keldAC1AcceptedStartupTraceRecord(token: token)
    let acceptedEvidence = StartupTraceEvidence(
        wvRunEnteredMilliseconds: 0,
        eventLoopCreatedMilliseconds: Double(46_906_000) / 1_000_000,
        windowBuiltMilliseconds: Double(95_141_000) / 1_000_000,
        webviewBuiltMilliseconds: Double(149_031_000) / 1_000_000
    )
    try require(
        try evaluateStartupTraceAfterAcceptedBeacon(record: accepted, expectedToken: token)
            == acceptedEvidence,
        "startup-trace evaluation must preserve the accepted AC1 four-stage record"
    )

    try requireStartupTraceMeasurementFailure(
        record: accepted.replacingOccurrences(of: "token=\(token)", with: "token=wrong-nonce"),
        expectedToken: token,
        defect: "wrong nonce"
    )
    try requireStartupTraceMeasurementFailure(
        record: accepted.replacingOccurrences(
            of: "event_loop_created_ns=46906000",
            with: "wv_run_entered_ns=46906000"
        ),
        expectedToken: token,
        defect: "duplicate stage"
    )
    try requireStartupTraceMeasurementFailure(
        record: accepted.replacingOccurrences(of: "webview_built_ns=149031000\n", with: ""),
        expectedToken: token,
        defect: "omitted stage"
    )
    try requireStartupTraceMeasurementFailure(
        record: accepted.replacingOccurrences(
            of: "webview_built_ns=149031000",
            with: "webview_built_ns=95141000"
        ),
        expectedToken: token,
        defect: "non-monotonic timestamps"
    )
    try requireStartupTraceMeasurementFailure(
        record: accepted.replacingOccurrences(
            of: "event_loop_created_ns=46906000\nwindow_built_ns=95141000",
            with: "window_built_ns=95141000\nevent_loop_created_ns=46906000"
        ),
        expectedToken: token,
        defect: "out-of-order stage fields"
    )

    let missingTraceOutput = try StartupTraceOutput.create(
        environmentVariable: "KELD_BENCH_STARTUP_TRACE",
        token: token
    )
    defer { missingTraceOutput.remove() }
    try require(
        (try? missingTraceOutput.readEvidence()) == nil,
        "startup-trace reader must reject a missing trace file"
    )
    try require(
        !FileManager.default.fileExists(atPath: missingTraceOutput.fileURL.path),
        "startup-trace output path must begin non-existent"
    )
    try require(
        isEnvironmentVariableName("KELD_BENCH_STARTUP_TRACE")
            && !isEnvironmentVariableName("keld_bench_startup_trace"),
        "startup-trace environment variable names must remain constrained"
    )
}

private func requireStartupTraceMeasurementFailure(
    record: String,
    expectedToken: String,
    defect: String
) throws {
    do {
        _ = try evaluateStartupTraceAfterAcceptedBeacon(
            record: record,
            expectedToken: expectedToken
        )
        throw HarnessError.measurement(
            "self-test failed: \(defect) was accepted and would publish a startup trace"
        )
    } catch let error as HarnessError {
        guard case .measurement(let message) = error else {
            throw HarnessError.measurement(
                "self-test failed: \(defect) was not a typed measurement failure: \(error)"
            )
        }
        if message.hasPrefix("self-test failed:") { throw error }
        try require(
            message.contains("startup trace"),
            "\(defect) must remain a startup-trace measurement failure; got \(message)"
        )
        try require(
            publicFailureCode(error) == "measurement_failure",
            "\(defect) must not publish a public result besides measurement_failure"
        )
    } catch {
        throw HarnessError.measurement(
            "self-test failed: \(defect) threw an unexpected error: \(error)"
        )
    }
}

@MainActor
private func runSelfTests(html: Data) async throws {
    try validateForegroundTransitionContract()
    try validatePublicEvidenceRedaction()
    try validateStartupTraceRejectionContract()
    let executableBinding = try LoadedExecutableBinding()
    let loadedExecutable = executableBinding.url
    let selfTestRepository = gitSnapshot(containing: loadedExecutable.deletingLastPathComponent())
    let selfTestHarnessArtifact = try harnessArtifactMetadata(
        executableBinding: executableBinding,
        repository: selfTestRepository
    )
    try require(
        selfTestHarnessArtifact.reproducibleBuild.attempted
            && selfTestHarnessArtifact.reproducibleBuild.byteForByteMatchesRunningExecutable
            && selfTestHarnessArtifact.reproducibleBuild.rebuiltExecutableSha256
                == selfTestHarnessArtifact.executableSha256,
        "running harness bytes must reproduce exactly from the recorded source and build command"
    )
    try require(
        !harnessRebuildEvidenceIsValid(
            HarnessRebuildEvidence(
                attempted: true,
                rebuiltExecutableSha256: selfTestHarnessArtifact.executableSha256,
                byteForByteMatchesRunningExecutable: false,
                loadedExecutableBoundToMappedVnode:
                    selfTestHarnessArtifact.reproducibleBuild.loadedExecutableBoundToMappedVnode,
                pathReplacementRejected:
                    selfTestHarnessArtifact.reproducibleBuild.pathReplacementRejected,
                immutableHeadBlobTreeVerified:
                    selfTestHarnessArtifact.reproducibleBuild.immutableHeadBlobTreeVerified,
                transientLiveSourceSubstitutionRejected:
                    selfTestHarnessArtifact.reproducibleBuild.transientLiveSourceSubstitutionRejected
            ),
            executableSha256: selfTestHarnessArtifact.executableSha256
        ),
        "publication provenance must reject a stale or substituted harness executable"
    )
    let server = try LoopbackBeaconServer(html: html)
    defer { server.stop() }

    let first = UUID().uuidString.lowercased()
    let wrong = UUID().uuidString.lowercased()
    try server.activate(token: first)
    try require(
        try rawHTTPStatus(port: server.port, request: "GET /beacon.gif?token=\(first)&phase=double-raf\r\n\r\n") == 400,
        "malformed request line must be rejected"
    )
    try require(
        try rawHTTPStatus(port: server.port, request: "GET /beacon.gif?token=\(first)&phase=double-raf HTTP/1.0\r\n\r\n") == 400,
        "unsupported HTTP version must be rejected"
    )
    try require(
        try rawHTTPStatus(port: server.port, request: "GET /beacon.gif?token=\(first)&phase=double-raf HTTP/1.1\r\n") == 400,
        "truncated headers must be rejected"
    )
    try require(try rawHTTPStatus(port: server.port, target: "/beacon.gif?phase=double-raf") == 400, "missing token must be rejected")
    let wrongTokenStatus = try rawHTTPStatus(port: server.port, target: "/beacon.gif?token=\(wrong)&phase=double-raf")
    try require(
        wrongTokenStatus == 403,
        "wrong token must be rejected with 403, got \(wrongTokenStatus); events=\(server.events(for: first))"
    )
    try require(try rawHTTPStatus(port: server.port, target: "/run/\(first)/hello.html?token=\(first)") == 200, "active canonical HTML must be served")
    try require(try rawHTTPStatus(port: server.port, target: "/beacon.gif?token=\(first)&phase=single-raf") == 422, "single-rAF negative control must be rejected")

    let second = UUID().uuidString.lowercased()
    try server.activate(token: second)
    try require(try rawHTTPStatus(port: server.port, target: "/beacon.gif?token=\(first)&phase=double-raf") == 410, "stale token must be rejected")
    try require(try rawHTTPStatus(port: server.port, target: "/run/\(second)/hello.html?token=\(second)") == 200, "second canonical HTML must be served")
    try require(try rawHTTPStatus(port: server.port, target: "/run/\(second)/hello.html?token=\(second)") == 409, "duplicate HTML request must be rejected")
    let beaconPrefix = "/beacon.gif?token=\(second)&phase=double-raf&"
    try require(try rawHTTPStatus(port: server.port, target: beaconPrefix + "client_now_ms=12&client_now_ms=13&script_start_ms=1&raf1_ms=8&raf2_ms=10&visibility=visible&focus=true") == 422, "duplicate diagnostic key must be rejected")
    try require(try rawHTTPStatus(port: server.port, target: beaconPrefix + "client_now_ms=nan&script_start_ms=1&raf1_ms=8&raf2_ms=10&visibility=visible&focus=true") == 422, "non-finite diagnostic must be rejected")
    try require(try rawHTTPStatus(port: server.port, target: beaconPrefix + "client_now_ms=12&script_start_ms=1&raf1_ms=10&raf2_ms=8&visibility=visible&focus=true") == 422, "unordered rAF diagnostic must be rejected")
    try require(try rawHTTPStatus(port: server.port, target: beaconPrefix + "client_now_ms=12&script_start_ms=1&raf2_ms=10&visibility=visible&focus=true") == 422, "missing diagnostic must be rejected")
    try require(server.events(for: second).last?.reason == "missing or invalid rendering-opportunity diagnostics", "missing diagnostic rejection reason must remain precise")
    try require(try rawHTTPStatus(port: server.port, target: beaconPrefix + "client_now_ms=12&script_start_ms=1&raf1_ms=8&raf2_ms=10&visibility=hidden&focus=false") == 422, "hidden document must be rejected")
    try require(server.events(for: second).last?.reason == "hidden document", "hidden-document rejection reason must remain precise")
    try require(try rawHTTPStatus(port: server.port, target: beaconPrefix + "client_now_ms=12&script_start_ms=1&raf1_ms=8&raf2_ms=10&visibility=visible&focus=false") == 422, "unfocused document must be rejected")
    try require(server.events(for: second).last?.reason == "unfocused document", "unfocused-document rejection reason must remain precise")
    try require(try rawHTTPStatus(port: server.port, target: beaconPrefix + "client_now_ms=12&script_start_ms=1&raf1_ms=8&raf2_ms=10&visibility=visible&focus=true&raf2_ms=9") == 422, "duplicate diagnostic must be rejected")
    try require(server.events(for: second).last?.reason == "missing or invalid rendering-opportunity diagnostics", "duplicate diagnostic must map to the missing-or-invalid reason")
    try require(try rawHTTPStatus(port: server.port, target: beaconPrefix + "client_now_ms=12&script_start_ms=-1&raf1_ms=8&raf2_ms=10&visibility=visible&focus=true") == 422, "negative script-start diagnostic must be rejected")
    try require(server.events(for: second).last?.reason == "negative script-start diagnostic", "negative script-start reason must remain precise")
    try require(try rawHTTPStatus(port: server.port, target: beaconPrefix + "client_now_ms=12&script_start_ms=1&raf1_ms=10&raf2_ms=8&visibility=visible&focus=true") == 422, "first rAF after second rAF must be rejected")
    try require(server.events(for: second).last?.reason == "first rAF after second rAF diagnostic", "rAF ordering reason must remain precise")
    try require(try rawHTTPStatus(port: server.port, target: beaconPrefix + "client_now_ms=9&script_start_ms=1&raf1_ms=8&raf2_ms=10&visibility=visible&focus=true") == 422, "second rAF after client-now must be rejected")
    try require(server.events(for: second).last?.reason == "second rAF after client-now diagnostic", "client-now ordering reason must remain precise")
    let diagnostics = "client_now_ms=12.5&script_start_ms=1.0&raf1_ms=8.0&raf2_ms=12.0&visibility=visible&focus=true"
    try require(try rawHTTPStatus(port: server.port, target: "/beacon.gif?token=\(second)&phase=double-raf&\(diagnostics)") == 204, "valid beacon must be accepted")
    try require(try rawHTTPStatus(port: server.port, target: beaconPrefix + diagnostics) == 409, "duplicate beacon must be rejected")
    let receipt = try await server.awaitBeacon(token: second, deadlineNanoseconds: monotonicNowNanoseconds() + 1_000_000_000)
    try require(receipt.token == second && receipt.clientNowMilliseconds == 12.5, "accepted receipt must retain authenticated metadata")
    server.finish(token: second)

    let frameTimestampBeforeScript = UUID().uuidString.lowercased()
    try server.activate(token: frameTimestampBeforeScript)
    try require(try rawHTTPStatus(port: server.port, target: "/run/\(frameTimestampBeforeScript)/hello.html?token=\(frameTimestampBeforeScript)") == 200, "frame-timestamp control HTML must load")
    let frameTimestampBeacon = "/beacon.gif?token=\(frameTimestampBeforeScript)&phase=double-raf&client_now_ms=12&script_start_ms=9&raf1_ms=8&raf2_ms=10&visibility=visible&focus=true"
    try require(try rawHTTPStatus(port: server.port, target: frameTimestampBeacon) == 204, "a frame timestamp preceding script performance.now() must remain a valid double-rAF beacon")
    let frameTimestampReceipt = try await server.awaitBeacon(token: frameTimestampBeforeScript, deadlineNanoseconds: monotonicNowNanoseconds() + 1_000_000_000)
    try require(frameTimestampReceipt.firstRafMilliseconds == 8 && frameTimestampReceipt.scriptStartMilliseconds == 9, "frame-timestamp control must preserve diagnostic metadata without treating it as rAF ordering")
    server.finish(token: frameTimestampBeforeScript)

    let noBeacon = UUID().uuidString.lowercased()
    try server.activate(token: noBeacon)
    try require(try rawHTTPStatus(port: server.port, target: "/run/\(noBeacon)/hello.html?token=\(noBeacon)") == 200, "timeout control HTML must load")
    do {
        _ = try await server.awaitBeacon(token: noBeacon, deadlineNanoseconds: monotonicNowNanoseconds() + 20_000_000)
        throw HarnessError.measurement("self-test failed: missing beacon unexpectedly completed")
    } catch HarnessError.timeout {
        // Expected timeout is the negative control; elapsed time is never success.
    } catch {
        throw HarnessError.measurement("self-test missing-beacon control returned the wrong error: \(error)")
    }
    try require(
        try rawHTTPStatus(
            port: server.port,
            target: "/beacon.gif?token=\(noBeacon)&phase=double-raf&client_now_ms=12&script_start_ms=1&raf1_ms=8&raf2_ms=10&visibility=visible&focus=true"
        ) == 408,
        "post-timeout beacon must remain rejected"
    )
    server.finish(token: noBeacon)

    var partialClient = try connectedLoopbackSocket(port: server.port)
    defer {
        if partialClient >= 0 { Darwin.close(partialClient) }
    }
    let partialRequest = Data("GET /incomplete HTTP/1.1\r\n".utf8)
    let partialBytesSent = partialRequest.withUnsafeBytes { buffer -> Int in
        guard let base = buffer.baseAddress else { return 0 }
        return Darwin.send(partialClient, base, buffer.count, 0)
    }
    try require(
        partialBytesSent == partialRequest.count,
        "partial-request quiescence control must reach the server"
    )
    let handlerStartDeadline = monotonicNowNanoseconds() + 1_000_000_000
    while server.activeClientHandlerCount() == 0,
          monotonicNowNanoseconds() < handlerStartDeadline {
        await nextObservationTick(nanoseconds: 1_000_000)
    }
    try require(
        server.activeClientHandlerCount() > 0,
        "partial-request control must hold a client handler open"
    )
    do {
        try await server.quiesceClientHandlers(
            deadlineNanoseconds: monotonicNowNanoseconds() + 20_000_000
        )
        throw HarnessError.measurement("self-test failed: active client handler quiesced before its deadline")
    } catch HarnessError.timeout(let message) {
        try require(
            message.contains("loopback client handler(s) remained active"),
            "client-handler timeout must report the unfinished count"
        )
    }
    Darwin.close(partialClient)
    partialClient = -1
    try await server.quiesceClientHandlers(
        deadlineNanoseconds: monotonicNowNanoseconds() + 2_000_000_000
    )

    let launchctlFixture = """
    pid/123 = {
      resource coalition = {
        ID = 456
        type = resource
        active count = 4
        name = application.com.example.Hello.123
        bundle ID = com.example.Hello
      }
    }
    """
    let identity = try ResourceCoalitionReader.parseLaunchctlIdentity(launchctlFixture)
    try require(identity.id == 456, "coalition ID parser")
    try require(identity.activeCount == 4, "coalition active-count parser")
    try require(identity.bundleIdentifier == "com.example.Hello", "coalition bundle parser")
    try require(try parseLaunchServicesOriginalPid("\"originalPid\"=731\n") == 731, "LaunchServices originalPid parser")
    try require(try parseLaunchServicesOriginalPid("\"originalPid\"=[ NULL ]\n") == nil, "LaunchServices NULL originalPid parser")
    try require(
        try parseLaunchServicesASN("\"LSASN\"=ASN:0x0-0x142142:\n") == "ASN:0x0-0x142142:",
        "LaunchServices ASN parser"
    )
    do {
        _ = try parseLaunchServicesASN("\"LSASN\"=#731\n")
        throw HarnessError.measurement("self-test failed: malformed ASN was accepted")
    } catch HarnessError.measurement(let message) where message == "lsappinfo returned malformed ASN output" {
        // Expected malformed-ASN rejection.
    }
    do {
        _ = try parseLaunchServicesOriginalPid("\"originalPid\"=garbage\n")
        throw HarnessError.measurement("self-test failed: malformed originalPid was accepted")
    } catch HarnessError.measurement(let message) where message == "lsappinfo returned an invalid originalPid value" {
        // Expected malformed-value rejection.
    }
    do {
        _ = try parseLaunchServicesOriginalPid("\"otherPid\"=731\n")
        throw HarnessError.measurement("self-test failed: wrong originalPid key was accepted")
    } catch HarnessError.measurement(let message) where message == "lsappinfo returned the wrong originalPid key" {
        // Expected wrong-key rejection.
    }
    try require(median([9, 1, 5, 3, 7]) == 5, "median calculation")
    try require(nearestRankPercentile(Array(1...11).map(Double.init), percentile: 0.9) == 10, "nearest-rank p90 calculation")
    try require(
        workingTreeState(from: CommandResult(status: 0, stdout: "", stderr: "")) == .clean,
        "zero-status empty git status must be clean"
    )
    try require(
        workingTreeState(from: CommandResult(status: 0, stdout: "?? file\n", stderr: "")) == .dirty,
        "zero-status nonempty git status must be dirty"
    )
    try require(
        workingTreeState(from: CommandResult(status: 128, stdout: "", stderr: "fatal")) == .unavailable,
        "nonzero git status must never be treated as clean"
    )
    let commandEnvironment = try runCommand("/usr/bin/env", [])
    try require(
        commandEnvironment.status == 0
            && commandEnvironment.stdout.split(whereSeparator: \.isNewline).contains("LC_ALL=C")
            && commandEnvironment.stdout.split(whereSeparator: \.isNewline).contains("LANG=C"),
        "measurement subprocesses must use a locale-independent environment"
    )
    try require(
        normalizedRepositoryIdentifier("git@github.com:gyldlab/keld-benches.git") == "github.com/gyldlab/keld-benches",
        "SSH repository identifiers must be credential-free"
    )
    guard let remoteProbe = canonicalRemoteProbe(
        repositoryIdentifier: canonicalBenchesRepositoryIdentifier
    ) else {
        throw HarnessError.measurement("self-test failed: canonical remote probe was unavailable")
    }
    try require(
        remoteProbe.arguments == [
            "-c", "protocol.file.allow=never",
            "ls-remote", "--heads", canonicalBenchesRemoteURL,
        ],
        "remote reachability must use the literal canonical URL"
    )
    try require(
        canonicalRemoteProbe(repositoryIdentifier: canonicalKeldRepositoryIdentifier)?.arguments == [
            "-c", "protocol.file.allow=never",
            "ls-remote", "--heads", canonicalKeldRemoteURL,
        ],
        "Keld source reachability must use its literal canonical URL"
    )
    try require(
        remoteProbe.currentDirectoryURL.path == "/var/empty",
        "remote reachability must run from the known non-repository directory"
    )
    let probeDirectoryStatus = try runCommand(
        "/usr/bin/git",
        ["rev-parse", "--show-toplevel"],
        currentDirectoryURL: remoteProbe.currentDirectoryURL
    )
    try require(
        probeDirectoryStatus.status == 128,
        "canonical remote probe directory must not be inside a Git working tree"
    )
    try require(
        canonicalRemoteProbe(repositoryIdentifier: "github.com/example/keld-benches") == nil,
        "remote reachability must reject a noncanonical repository identifier"
    )
    try require(isPublicArgumentTemplate("--title=Hello"), "safe public launch argument")
    try require(!isPublicArgumentTemplate("--config=/Users/example/private"), "absolute launch argument must be unsafe")
    try require(thermalStateName(.nominal) == "nominal", "nominal thermal state must use a stable publication value")
    let recipeCommit = String(repeating: "a", count: 40)
    let recipeSourceFiles = [
        ArtifactHash(
            repositoryRelativePath: "macos/keld/hello/keld-bench-url.patch",
            sha256: String(repeating: "b", count: 64),
            matchesHeadBlob: true
        ),
        ArtifactHash(
            repositoryRelativePath: "macos/keld/hello/build.sh",
            sha256: String(repeating: "c", count: 64),
            matchesHeadBlob: true
        ),
        ArtifactHash(
            repositoryRelativePath: "macos/keld/hello/Info.plist",
            sha256: String(repeating: "d", count: 64),
            matchesHeadBlob: true
        ),
    ]
    try require(
        embeddedAdapterRecipeFieldsMatch(
            recipeRepository: canonicalBenchesRepositoryIdentifier,
            recipeCommit: recipeCommit,
            buildRecipe: "macos/keld/hello/build.sh SOURCE SHA OUTPUT_APP",
            patchSha256: String(repeating: "b", count: 64),
            buildScriptSha256: String(repeating: "c", count: 64),
            infoPlistSha256: String(repeating: "d", count: 64),
            harnessCommit: recipeCommit,
            sourceFiles: recipeSourceFiles
        ),
        "embedded adapter provenance must match committed recipe files"
    )
    try require(
        !embeddedAdapterRecipeFieldsMatch(
            recipeRepository: canonicalBenchesRepositoryIdentifier,
            recipeCommit: recipeCommit,
            buildRecipe: "macos/keld/hello/build.sh SOURCE SHA OUTPUT_APP",
            patchSha256: String(repeating: "e", count: 64),
            buildScriptSha256: String(repeating: "c", count: 64),
            infoPlistSha256: String(repeating: "d", count: 64),
            harnessCommit: recipeCommit,
            sourceFiles: recipeSourceFiles
        ),
        "embedded adapter provenance must reject a mismatched patch"
    )
    try require(
        !embeddedAdapterRecipeFieldsMatch(
            recipeRepository: canonicalBenchesRepositoryIdentifier,
            recipeCommit: recipeCommit,
            buildRecipe: "macos/keld/hello/build.sh SOURCE SHA OUTPUT_APP",
            patchSha256: String(repeating: "b", count: 64),
            buildScriptSha256: String(repeating: "c", count: 64),
            infoPlistSha256: String(repeating: "e", count: 64),
            harnessCommit: recipeCommit,
            sourceFiles: recipeSourceFiles
        ),
        "embedded adapter provenance must reject a mismatched Info.plist template"
    )
    let tauriRecipeSourceFiles = [
        ArtifactHash(
            repositoryRelativePath: "macos/tauri/hello/build.sh",
            sha256: String(repeating: "f", count: 64),
            matchesHeadBlob: true
        ),
    ]
    let tauriBuildCommandSha256 = sha256Hex(Data("macos/tauri/hello/build.sh".utf8))
    try require(
        embeddedTauriRecipeFieldsMatch(
            sourceRepository: canonicalBenchesRepositoryIdentifier,
            sourceCommit: recipeCommit,
            sourceRelativePath: "macos/tauri/hello",
            recipeRepository: canonicalBenchesRepositoryIdentifier,
            recipeCommit: recipeCommit,
            buildRecipe: "macos/tauri/hello/build.sh",
            buildScriptSha256: String(repeating: "f", count: 64),
            buildCommandSha256: tauriBuildCommandSha256,
            harnessCommit: recipeCommit,
            sourceFiles: tauriRecipeSourceFiles
        ),
        "embedded Tauri provenance must bind the app to the current committed build recipe"
    )
    try require(
        !embeddedTauriRecipeFieldsMatch(
            sourceRepository: canonicalBenchesRepositoryIdentifier,
            sourceCommit: String(repeating: "b", count: 40),
            sourceRelativePath: "macos/tauri/hello",
            recipeRepository: canonicalBenchesRepositoryIdentifier,
            recipeCommit: recipeCommit,
            buildRecipe: "macos/tauri/hello/build.sh",
            buildScriptSha256: String(repeating: "f", count: 64),
            buildCommandSha256: tauriBuildCommandSha256,
            harnessCommit: recipeCommit,
            sourceFiles: tauriRecipeSourceFiles
        ),
        "embedded Tauri provenance must reject an app from a stale source commit"
    )
    try require(
        !embeddedTauriRecipeFieldsMatch(
            sourceRepository: canonicalBenchesRepositoryIdentifier,
            sourceCommit: recipeCommit,
            sourceRelativePath: "macos/tauri/hello",
            recipeRepository: canonicalBenchesRepositoryIdentifier,
            recipeCommit: recipeCommit,
            buildRecipe: "macos/tauri/hello/build.sh",
            buildScriptSha256: String(repeating: "0", count: 64),
            buildCommandSha256: tauriBuildCommandSha256,
            harnessCommit: recipeCommit,
            sourceFiles: tauriRecipeSourceFiles
        ),
        "embedded Tauri provenance must reject a mismatched build script"
    )

    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("keld-macos-harness-self-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let boundaryRepository = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
    let prefixSibling = temporaryRoot.appendingPathComponent("repository-sibling", isDirectory: true)
    let siblingCargo = prefixSibling.appendingPathComponent("src-tauri", isDirectory: true)
    let siblingApp = prefixSibling
        .appendingPathComponent("target", isDirectory: true)
        .appendingPathComponent("Sibling.app", isDirectory: true)
    try FileManager.default.createDirectory(at: boundaryRepository, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: siblingCargo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: siblingApp, withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: prefixSibling.appendingPathComponent("package.json"))
    try Data("lock\n".utf8).write(to: prefixSibling.appendingPathComponent("bun.lock"))
    try Data("[package]\nname='sibling'\n".utf8).write(
        to: siblingCargo.appendingPathComponent("Cargo.toml")
    )
    try require(
        nearestTauriSourceRoot(from: siblingApp, repositoryRoot: boundaryRepository) == nil,
        "Tauri source discovery must reject a same-prefix sibling repository"
    )

    let unreadableRepository = temporaryRoot.appendingPathComponent("unreadable-repository", isDirectory: true)
    let unreadableGitMarker = unreadableRepository.appendingPathComponent(".git", isDirectory: true)
    let unreadableOutputParent = unreadableRepository.appendingPathComponent("results", isDirectory: true)
    try FileManager.default.createDirectory(at: unreadableGitMarker, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unreadableOutputParent, withIntermediateDirectories: true)
    guard Darwin.chmod(unreadableGitMarker.path, 0) == 0 else {
        throw HarnessError.io("self-test could not make the Git marker unreadable")
    }
    defer { _ = Darwin.chmod(unreadableGitMarker.path, S_IRWXU) }
    do {
        try requireDirectoryOutsideGitWorkingTree(unreadableOutputParent)
        throw HarnessError.measurement("self-test failed: unreadable Git working tree was accepted")
    } catch HarnessError.invalidArgument(let message)
        where message == "--output must be outside every Git working tree" {
        // The marker is detected directly; Git exit status cannot hide it.
    }
    guard Darwin.chmod(unreadableGitMarker.path, S_IRWXU) == 0 else {
        throw HarnessError.io("self-test could not restore Git marker permissions")
    }

    func runSelfTestGit(_ arguments: [String]) throws -> CommandResult {
        let result = try runCommand("/usr/bin/git", arguments)
        guard result.status == 0 else {
            throw HarnessError.io("self-test Git command failed: \(result.stderr)")
        }
        return result
    }

    let maskedRepository = temporaryRoot.appendingPathComponent("masked-repository", isDirectory: true)
    try FileManager.default.createDirectory(at: maskedRepository, withIntermediateDirectories: false)
    _ = try runSelfTestGit(["-C", maskedRepository.path, "init", "--quiet"])
    _ = try runSelfTestGit(["-C", maskedRepository.path, "config", "user.name", "Keld Harness Self Test"])
    _ = try runSelfTestGit(["-C", maskedRepository.path, "config", "user.email", "self-test@example.invalid"])
    _ = try runSelfTestGit([
        "-C", maskedRepository.path,
        "config", "filter.mask.clean", "/usr/bin/sed 's/bravo/alpha/'",
    ])
    _ = try runSelfTestGit(["-C", maskedRepository.path, "config", "filter.mask.smudge", "cat"])
    let attributesFile = maskedRepository.appendingPathComponent(".gitattributes")
    let maskedFile = maskedRepository.appendingPathComponent("tracked.txt")
    try Data("tracked.txt filter=mask\n".utf8).write(to: attributesFile)
    try Data("alpha\n".utf8).write(to: maskedFile)
    _ = try runSelfTestGit(["-C", maskedRepository.path, "add", ".gitattributes", "tracked.txt"])
    _ = try runSelfTestGit(["-C", maskedRepository.path, "commit", "--quiet", "-m", "fixture"])
    let maskedCommit = gitSnapshot(containing: maskedRepository).metadata.commit
    guard let maskedCommit else {
        throw HarnessError.measurement("self-test failed: masked repository commit was unavailable")
    }
    try require(
        try hashFile(
            maskedFile,
            relativeTo: maskedRepository,
            snapshotCommit: maskedCommit
        ).matchesHeadBlob,
        "unchanged raw working-tree bytes must match the HEAD blob"
    )
    try Data("bravo\n".utf8).write(to: maskedFile)
    let cleanFilterStatus = try runSelfTestGit([
        "-C", maskedRepository.path,
        "status", "--porcelain=v1", "--untracked-files=all",
    ])
    try require(
        cleanFilterStatus.stdout.isEmpty,
        "clean-filter negative control must actually mask the changed file from Git status"
    )
    try require(
        try !hashFile(
            maskedFile,
            relativeTo: maskedRepository,
            snapshotCommit: maskedCommit
        ).matchesHeadBlob,
        "raw HEAD-blob comparison must reject bytes hidden by a clean filter"
    )
    try Data("alpha\n".utf8).write(to: maskedFile)
    _ = try runSelfTestGit(["-C", maskedRepository.path, "update-index", "--assume-unchanged", "tracked.txt"])
    try Data("charlie\n".utf8).write(to: maskedFile)
    let assumeUnchangedStatus = try runSelfTestGit([
        "-C", maskedRepository.path,
        "status", "--porcelain=v1", "--untracked-files=all",
    ])
    try require(
        assumeUnchangedStatus.stdout.isEmpty,
        "assume-unchanged negative control must actually mask the changed file from Git status"
    )
    try require(
        try !hashFile(
            maskedFile,
            relativeTo: maskedRepository,
            snapshotCommit: maskedCommit
        ).matchesHeadBlob,
        "raw HEAD-blob comparison must reject bytes hidden by assume-unchanged"
    )

    let originalDirectory = temporaryRoot.appendingPathComponent("original", isDirectory: true)
    let retainedDirectory = temporaryRoot.appendingPathComponent("retained", isDirectory: true)
    let alias = temporaryRoot.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: originalDirectory)
    let originalIdentity = try fileIdentity(at: originalDirectory)
    try require(try fileIdentity(at: alias) == originalIdentity, "bundle file identity must follow path aliases")
    try FileManager.default.moveItem(at: originalDirectory, to: retainedDirectory)
    try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: false)
    try require(try fileIdentity(at: originalDirectory) != originalIdentity, "bundle replacement at the same path must change identity")

    let bundleRoot = temporaryRoot.appendingPathComponent("Fixture.app", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: false)
    let payload = bundleRoot.appendingPathComponent("payload")
    try Data("alpha".utf8).write(to: payload)
    let safeDiagnosticOutput = temporaryRoot.appendingPathComponent("diagnostic.json")
    try require(
        try validatedOutputURL(
            safeDiagnosticOutput,
            repositoryRoot: nil,
            harnessExecutable: payload,
            htmlURL: payload,
            apps: []
        )?.url == safeDiagnosticOutput,
        "nonexisting diagnostic output must be accepted"
    )
    do {
        _ = try validatedOutputURL(
            bundleRoot.appendingPathComponent("result.json"),
            repositoryRoot: temporaryRoot,
            harnessExecutable: payload,
            htmlURL: payload,
            apps: [AppSpec(
                label: "fixture",
                bundleURL: bundleRoot,
                bundleFileIdentity: try fileIdentity(at: bundleRoot),
                argumentTemplates: [],
                buildCommand: "test",
                startupTraceEnvironmentVariable: nil
            )]
        )
        throw HarnessError.measurement("self-test failed: output inside a measured bundle was accepted")
    } catch HarnessError.invalidArgument(let message)
        where message == "--output must be outside every measured app bundle" {
        // Expected measured-bundle protection.
    }
    do {
        _ = try validatedOutputURL(
            safeDiagnosticOutput,
            repositoryRoot: temporaryRoot,
            harnessExecutable: payload,
            htmlURL: payload,
            apps: []
        )
        throw HarnessError.measurement("self-test failed: publication output inside the source repository was accepted")
    } catch HarnessError.invalidArgument(let message)
        where message == "--output must be outside the benchmark repository" {
        // Expected publication-path isolation.
    }
    guard let collisionDestination = try validatedOutputURL(
        safeDiagnosticOutput,
        repositoryRoot: nil,
        harnessExecutable: payload,
        htmlURL: payload,
        apps: []
    ) else {
        throw HarnessError.measurement("self-test failed: collision destination was unavailable")
    }
    try Data("occupied".utf8).write(to: safeDiagnosticOutput)
    let capturedStandardOutput = temporaryRoot.appendingPathComponent("captured-stdout")
    guard FileManager.default.createFile(atPath: capturedStandardOutput.path, contents: nil) else {
        throw HarnessError.io("self-test could not create the stdout capture")
    }
    let capturedStandardOutputHandle = try FileHandle(forWritingTo: capturedStandardOutput)
    var outputFailureObserved = false
    do {
        try emitBenchmarkJSON(
            Data("{\"publication\":{\"eligible\":true}}".utf8),
            outputDestination: collisionDestination,
            standardOutput: capturedStandardOutputHandle
        )
    } catch HarnessError.io {
        outputFailureObserved = true
    }
    try capturedStandardOutputHandle.close()
    try require(outputFailureObserved, "exclusive output collision must fail publication emission")
    try require(
        try Data(contentsOf: capturedStandardOutput).isEmpty,
        "failed atomic output must not emit an eligibility claim to stdout"
    )
    try require(
        try Data(contentsOf: safeDiagnosticOutput) == Data("occupied".utf8),
        "atomic output must not overwrite an existing destination"
    )
    let baselineBundleHash = try bundleTreeSha256(bundleRoot)
    try Data("bravo".utf8).write(to: payload)
    try require(try bundleTreeSha256(bundleRoot) != baselineBundleHash, "bundle hash must include file bytes")
    try Data("alpha".utf8).write(to: payload)
    let emptyDirectory = bundleRoot.appendingPathComponent("empty", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: false)
    try require(try bundleTreeSha256(bundleRoot) != baselineBundleHash, "bundle hash must include empty directories")
    try FileManager.default.removeItem(at: emptyDirectory)
    let payloadLink = bundleRoot.appendingPathComponent("payload-link")
    try FileManager.default.createSymbolicLink(atPath: payloadLink.path, withDestinationPath: "payload")
    try require(try bundleTreeSha256(bundleRoot) != baselineBundleHash, "bundle hash must include symbolic-link targets")
    try FileManager.default.removeItem(at: payloadLink)
    let payloadAttributes = try FileManager.default.attributesOfItem(atPath: payload.path)
    guard let originalMode = (payloadAttributes[.posixPermissions] as? NSNumber)?.uint16Value else {
        throw HarnessError.measurement("self-test failed: could not read payload permissions")
    }
    let changedMode = mode_t(originalMode ^ UInt16(S_IXUSR))
    guard Darwin.chmod(payload.path, changedMode) == 0 else {
        throw HarnessError.io("self-test chmod failed: \(String(cString: strerror(errno)))")
    }
    try require(try bundleTreeSha256(bundleRoot) != baselineBundleHash, "bundle hash must include POSIX mode")
    guard Darwin.chmod(payload.path, mode_t(originalMode)) == 0 else {
        throw HarnessError.io("self-test chmod restore failed: \(String(cString: strerror(errno)))")
    }

    let processRows = try ResourceCoalitionReader.parseProcessRows(
        "731 1 2048 Fri Aug 15 10:11:12 2026 /Applications/Hello App.app/Contents/MacOS/hello --flag\n"
    )
    try require(
        processRows.count == 1
            && processRows[0].pid == 731
            && processRows[0].rssKiB == 2_048
            && processRows[0].command.hasSuffix("hello --flag"),
        "ps parser must preserve commands containing spaces"
    )
    try require(
        try ResourceCoalitionReader.validatedCoalitionPids(
            [733, 731, 732],
            id: 456,
            byteCount: 3 * MemoryLayout<Int32>.size
        ) == [731, 732, 733],
        "coalition PID validation must return a canonical ordering"
    )
    do {
        _ = try ResourceCoalitionReader.validatedCoalitionPids(
            [731, 732, 732],
            id: 456,
            byteCount: 3 * MemoryLayout<Int32>.size
        )
        throw HarnessError.measurement("self-test failed: duplicate coalition PID was accepted")
    } catch is CoalitionProcessSetChanged {
        // Expected: a PID-only duplicate cannot identify both generations, so
        // the complete observation must be discarded as membership churn.
    }
    do {
        _ = try ResourceCoalitionReader.validatedCoalitionPids(
            [731, 0],
            id: 456,
            byteCount: 2 * MemoryLayout<Int32>.size
        )
        throw HarnessError.measurement("self-test failed: nonpositive coalition PID was accepted")
    } catch HarnessError.measurement(let message)
        where message.hasPrefix("coalition_info_pid_list(456) returned a nonpositive PID") {
        // Expected malformed-ABI hard failure; this must not be retried as churn.
    }
    let selfReader = ResourceCoalitionReader()
    let ownCoalition = try selfReader.identity(for: getpid())
    try require(
        try selfReader.coalitionMemberPids(id: ownCoalition.id).contains(getpid()),
        "runtime coalition enumeration must include the calling process"
    )
    let ownLifecycle = try selfReader.coalitionLifecycleCounters(id: ownCoalition.id)
    try require(
        ownLifecycle.tasksStarted >= ownLifecycle.tasksExited,
        "runtime coalition lifecycle counters must be internally consistent"
    )
    guard let ownUniqueIdentity = try kernelProcessUniqueIdentity(for: getpid()),
          let ownLaunchOwnership = try kernelLaunchOwnership(for: getpid()) else {
        throw HarnessError.measurement("self-test failed: kernel process ownership was unavailable")
    }
    try require(
        ownLaunchOwnership.uniqueId == ownUniqueIdentity.uniqueId
            && ownLaunchOwnership.resourceCoalitionId == ownCoalition.id,
        "generation-bound launch ownership must match the live process and coalition"
    )
    try validateKernelGenerationSignalContract()

    let stubbornApp = try buildStubbornCleanupSelfTestApp(temporaryRoot: temporaryRoot)
    try await validateStubbornCleanupContract(
        appURL: stubbornApp,
        server: server,
        reader: selfReader,
        injectFailureAfterChildCapture: false
    )
    try await validateStubbornCleanupContract(
        appURL: stubbornApp,
        server: server,
        reader: selfReader,
        injectFailureAfterChildCapture: true
    )
    try require(
        hasUnresolvedLaunchOwnership([
            CleanupRecord(
                gracefulTerminateAccepted: false,
                coalitionHardKillInvoked: false,
                applicationTerminated: false,
                coalitionDrained: false,
                error: "process_identity_unavailable"
            ),
        ]),
        "unresolved launch ownership must trigger output quarantine"
    )

    let cleanRepository = RepositoryMetadata(
        identifier: "github.com/gyldlab/keld-benches",
        commit: String(repeating: "a", count: 40),
        workingTreeState: .clean,
        commitAdvertisedAsOriginHead: true
    )
    let nominalHost = HostMetadata(
        operatingSystemVersion: "test",
        architecture: "arm64",
        hardwareModel: "test",
        processor: "test",
        logicalCpuCount: 1,
        physicalMemoryBytes: 1,
        lowPowerModeEnabled: false,
        thermalState: "nominal"
    )
    let completeArm = PublicationArmFacts(
        label: "fixture",
        sampleCount: 11,
        successfulSampleCount: 11,
        completeCleanupCount: 11,
        completeMetricCount: 11,
        completeForegroundCount: 11,
        fixtureUnchanged: true,
        provenanceComplete: true,
        adapterRecipeMatches: true,
        toolchainComplete: true,
        publicArgumentsSafe: true,
        sampleHostConditionsAcceptable: true
    )
    try validateForegroundPublicationPolicyContract()
    let nonNominalSampleArm = PublicationArmFacts(
        label: "fixture",
        sampleCount: 11,
        successfulSampleCount: 11,
        completeCleanupCount: 11,
        completeMetricCount: 11,
        completeForegroundCount: 11,
        fixtureUnchanged: true,
        provenanceComplete: true,
        adapterRecipeMatches: true,
        toolchainComplete: true,
        publicArgumentsSafe: true,
        sampleHostConditionsAcceptable: false
    )
    let nonNominalSampleFacts = PublicationFacts(
        runsPerApp: 11,
        stableCoalitionObservations: 3,
        stableCoalitionWindowMilliseconds: 500,
        rssToleranceKiB: 1_024,
        repositoryBefore: cleanRepository,
        repositoryAfter: cleanRepository,
        harnessProvenanceComplete: true,
        canonicalHTML: true,
        publicationOutputProvided: true,
        outputWillPreserveCleanTree: true,
        hostBefore: nominalHost,
        hostAfter: nominalHost,
        aborted: false,
        foregroundSessionProofComplete: true,
        recordedSampleCount: 11,
        foregroundSessionStartedSampleCount: 11,
        foregroundSessionExactRestorationCount: 11,
        foregroundSessionFinishedSampleCount: 11,
        arms: [nonNominalSampleArm]
    )
    try require(
        publicationAssessment(requested: true, facts: nonNominalSampleFacts).reasons.contains {
            $0.code == "sample_host_state_not_nominal"
        },
        "publication policy must reject transient per-sample thermal or Low Power Mode state"
    )
    let shortRun = PublicationFacts(
        runsPerApp: 10,
        stableCoalitionObservations: 3,
        stableCoalitionWindowMilliseconds: 500,
        rssToleranceKiB: 1_024,
        repositoryBefore: cleanRepository,
        repositoryAfter: cleanRepository,
        harnessProvenanceComplete: true,
        canonicalHTML: true,
        publicationOutputProvided: true,
        outputWillPreserveCleanTree: true,
        hostBefore: nominalHost,
        hostAfter: nominalHost,
        aborted: false,
        foregroundSessionProofComplete: true,
        recordedSampleCount: 10,
        foregroundSessionStartedSampleCount: 10,
        foregroundSessionExactRestorationCount: 10,
        foregroundSessionFinishedSampleCount: 10,
        arms: [PublicationArmFacts(
            label: "fixture",
            sampleCount: 10,
            successfulSampleCount: 10,
            completeCleanupCount: 10,
            completeMetricCount: 10,
            completeForegroundCount: 10,
            fixtureUnchanged: true,
            provenanceComplete: true,
            adapterRecipeMatches: true,
            toolchainComplete: true,
            publicArgumentsSafe: true,
            sampleHostConditionsAcceptable: true
        )]
    )
    let shortAssessment = publicationAssessment(requested: true, facts: shortRun)
    try require(
        !shortAssessment.eligible
            && shortAssessment.reasons.contains { $0.code == "runs_per_arm_not_11" }
            && shortAssessment.reasons.contains { $0.code == "sample_count_mismatch" },
        "publication policy must reject a non-11-sample arm with stable reason codes"
    )
    let weakenedStability = PublicationFacts(
        runsPerApp: 11,
        stableCoalitionObservations: 3,
        stableCoalitionWindowMilliseconds: 499,
        rssToleranceKiB: 1_024,
        repositoryBefore: cleanRepository,
        repositoryAfter: cleanRepository,
        harnessProvenanceComplete: true,
        canonicalHTML: true,
        publicationOutputProvided: true,
        outputWillPreserveCleanTree: true,
        hostBefore: nominalHost,
        hostAfter: nominalHost,
        aborted: false,
        foregroundSessionProofComplete: true,
        recordedSampleCount: 11,
        foregroundSessionStartedSampleCount: 11,
        foregroundSessionExactRestorationCount: 11,
        foregroundSessionFinishedSampleCount: 11,
        arms: [completeArm]
    )
    try require(
        publicationAssessment(requested: true, facts: weakenedStability).reasons.contains {
            $0.code == "rss_stability_policy_weakened"
        },
        "publication policy must reject a weakened RSS stability window"
    )
    let incompleteHost = HostMetadata(
        operatingSystemVersion: "test",
        architecture: "arm64",
        hardwareModel: "test",
        processor: "unknown",
        logicalCpuCount: 1,
        physicalMemoryBytes: 1,
        lowPowerModeEnabled: false,
        thermalState: "nominal"
    )
    let incompleteHostFacts = PublicationFacts(
        runsPerApp: 11,
        stableCoalitionObservations: 3,
        stableCoalitionWindowMilliseconds: 500,
        rssToleranceKiB: 1_024,
        repositoryBefore: cleanRepository,
        repositoryAfter: cleanRepository,
        harnessProvenanceComplete: true,
        canonicalHTML: true,
        publicationOutputProvided: true,
        outputWillPreserveCleanTree: true,
        hostBefore: incompleteHost,
        hostAfter: incompleteHost,
        aborted: false,
        foregroundSessionProofComplete: true,
        recordedSampleCount: 11,
        foregroundSessionStartedSampleCount: 11,
        foregroundSessionExactRestorationCount: 11,
        foregroundSessionFinishedSampleCount: 11,
        arms: [completeArm]
    )
    try require(
        publicationAssessment(requested: true, facts: incompleteHostFacts).reasons.contains {
            $0.code == "host_metadata_unavailable"
        },
        "publication policy must reject incomplete host metadata"
    )
    let unpublishedRepository = RepositoryMetadata(
        identifier: canonicalBenchesRepositoryIdentifier,
        commit: String(repeating: "a", count: 40),
        workingTreeState: .clean,
        commitAdvertisedAsOriginHead: false
    )
    let unpublishedFacts = PublicationFacts(
        runsPerApp: 11,
        stableCoalitionObservations: 3,
        stableCoalitionWindowMilliseconds: 500,
        rssToleranceKiB: 1_024,
        repositoryBefore: unpublishedRepository,
        repositoryAfter: unpublishedRepository,
        harnessProvenanceComplete: true,
        canonicalHTML: true,
        publicationOutputProvided: true,
        outputWillPreserveCleanTree: true,
        hostBefore: nominalHost,
        hostAfter: nominalHost,
        aborted: false,
        foregroundSessionProofComplete: true,
        recordedSampleCount: 11,
        foregroundSessionStartedSampleCount: 11,
        foregroundSessionExactRestorationCount: 11,
        foregroundSessionFinishedSampleCount: 11,
        arms: [completeArm]
    )
    try require(
        publicationAssessment(requested: true, facts: unpublishedFacts).reasons.contains {
            $0.code == "repository_commit_not_advertised_as_origin_head"
        },
        "publication policy must reject a commit absent from current origin branch heads"
    )
    let mismatchedAdapterArm = PublicationArmFacts(
        label: "fixture",
        sampleCount: 11,
        successfulSampleCount: 11,
        completeCleanupCount: 11,
        completeMetricCount: 11,
        completeForegroundCount: 11,
        fixtureUnchanged: true,
        provenanceComplete: true,
        adapterRecipeMatches: false,
        toolchainComplete: true,
        publicArgumentsSafe: true,
        sampleHostConditionsAcceptable: true
    )
    let mismatchedAdapterFacts = PublicationFacts(
        runsPerApp: 11,
        stableCoalitionObservations: 3,
        stableCoalitionWindowMilliseconds: 500,
        rssToleranceKiB: 1_024,
        repositoryBefore: cleanRepository,
        repositoryAfter: cleanRepository,
        harnessProvenanceComplete: true,
        canonicalHTML: true,
        publicationOutputProvided: true,
        outputWillPreserveCleanTree: true,
        hostBefore: nominalHost,
        hostAfter: nominalHost,
        aborted: false,
        foregroundSessionProofComplete: true,
        recordedSampleCount: 11,
        foregroundSessionStartedSampleCount: 11,
        foregroundSessionExactRestorationCount: 11,
        foregroundSessionFinishedSampleCount: 11,
        arms: [mismatchedAdapterArm]
    )
    try require(
        publicationAssessment(requested: true, facts: mismatchedAdapterFacts).reasons.contains {
            $0.code == "fixture_adapter_recipe_mismatch"
        },
        "publication policy must reject a mismatched adapter recipe"
    )

    FileHandle.standardError.write(Data("self-test: all protocol, parser, and negative controls passed\n".utf8))
}

@MainActor
private func runBenchmark(options: RunnerOptions, htmlURL: URL, html: Data) async throws -> BenchmarkOutcome {
    guard !options.apps.isEmpty else {
        throw HarnessError.invalidArgument("at least one --app is required")
    }
    guard !(options.publish && options.apps.contains { $0.startupTraceEnvironmentVariable != nil }) else {
        throw HarnessError.invalidArgument(
            "--app-startup-trace is diagnostic-only; run trace-disabled arms before requesting --publish"
        )
    }
    guard try kernelLaunchOwnership(for: getpid()) != nil else {
        throw HarnessError.measurement(
            "generation-bound process and coalition ownership is unavailable on this macOS build"
        )
    }
    try validateKernelGenerationSignalContract()
    let executableBinding = try LoadedExecutableBinding()
    let harnessExecutable = executableBinding.url
    let repositoryBefore = gitSnapshot(containing: harnessExecutable.deletingLastPathComponent())
    let outputURL = try validatedOutputURL(
        options.outputURL,
        repositoryRoot: repositoryBefore.rootURL,
        harnessExecutable: harnessExecutable,
        htmlURL: htmlURL,
        apps: options.apps
    )
    let hostBefore = hostMetadata()
    let fixtureMetadataBefore = try options.apps.map(fixtureMetadata)
    let server = try LoopbackBeaconServer(html: html)
    defer { server.stop() }
    let reader = ResourceCoalitionReader()
    let foregroundSession = try ForegroundSessionMonitor.capture()
    defer { foregroundSession.stop() }

    let started = Date()
    var samples: [SampleRecord] = []
    var globalOrdinal = 0
    var abortedReason: String?
    benchmarkRounds: for round in 0..<options.runsPerApp {
        // Rotate the first app each round. Every app receives one sample per
        // round, but persistent thermal/order bias is not assigned to one label.
        for offset in 0..<options.apps.count {
            let appIndex = (round + offset) % options.apps.count
            let spec = options.apps[appIndex]
            globalOrdinal += 1
            FileHandle.standardError.write(Data("[\(globalOrdinal)/\(options.runsPerApp * options.apps.count)] \(spec.label), round \(round + 1)\n".utf8))
            let foregroundMonitor = try foregroundSession.beginSample()
            let sample = await runOneSample(
                spec: spec,
                round: round + 1,
                appOrdinal: appIndex + 1,
                globalOrdinal: globalOrdinal,
                options: options,
                server: server,
                reader: reader,
                foregroundMonitor: foregroundMonitor
            )
            samples.append(sample)
            if sample.status != "ok" {
                abortedReason = "sample failed after \(spec.label) round \(round + 1); later arms were not launched"
                break benchmarkRounds
            }
            if sample.cleanup?.applicationTerminated != true
                || sample.cleanup?.coalitionDrained != true
                || sample.cleanup?.error != nil {
                abortedReason = "cleanup proof failed after \(spec.label) round \(round + 1); later arms were not launched"
                break benchmarkRounds
            }
        }
    }
    let foregroundSessionEvidence = foregroundSession.finishArms()
    let foregroundSessionProofComplete = foregroundSessionEvidence
        .isCompleteForPublication(recordedSampleCount: samples.count)
    abortedReason = abortedReasonAfterForegroundSessionFinalization(
        existingAbortedReason: abortedReason,
        foregroundSessionProofComplete: foregroundSessionProofComplete
    )
    foregroundSession.stop()

    if hasUnresolvedLaunchOwnership(samples.map(\.cleanup)) {
        throw HarnessError.measurement(
            "launch ownership unresolved; no JSON was emitted because pre-callback descendants cannot be contained—terminate any new fixture descendants before rerunning"
        )
    }

    let fixtureMetadataAfter = try options.apps.map(fixtureMetadata)
    let hostAfter = hostMetadata()
    // Rebuild verification is intentionally after every scored sample and host
    // observation so compiler work cannot perturb launch timing or RSS.
    let harnessArtifact = try harnessArtifactMetadata(
        executableBinding: executableBinding,
        repository: repositoryBefore
    )
    let repositoryAfter = gitSnapshot(containing: harnessExecutable.deletingLastPathComponent())
    let canonicalHTML: Bool
    if let repositoryRoot = repositoryBefore.rootURL,
       let commit = repositoryBefore.metadata.commit {
        canonicalHTML = (try? immutableGitBlob(
            repositoryRoot: repositoryRoot,
            commit: commit,
            relativePath: "macos/harness/hello.html"
        ).data) == html
    } else {
        canonicalHTML = false
    }
    let changedFixtureLabels = zip(fixtureMetadataBefore, fixtureMetadataAfter).compactMap { before, after in
        before == after ? nil : before.label
    }
    if !changedFixtureLabels.isEmpty, abortedReason == nil {
        abortedReason = "fixture provenance changed during the benchmark: \(changedFixtureLabels.joined(separator: ", "))"
    }
    let armFacts = options.apps.enumerated().map { index, app in
        let appSamples = samples.filter { $0.label == app.label }
        let fixtureBefore = fixtureMetadataBefore[index]
        let fixtureAfter = fixtureMetadataAfter[index]
        return PublicationArmFacts(
            label: app.label,
            sampleCount: appSamples.count,
            successfulSampleCount: appSamples.filter { $0.status == "ok" }.count,
            completeCleanupCount: appSamples.filter {
                $0.cleanup?.applicationTerminated == true
                    && $0.cleanup?.coalitionDrained == true
                    && $0.cleanup?.error == nil
            }.count,
            completeMetricCount: appSamples.filter {
                $0.doubleRafPaintOpportunityProxyMilliseconds != nil
                    && $0.coalition != nil
            }.count,
            completeForegroundCount: appSamples.filter {
                $0.foreground.isCompleteForPublication
            }.count,
            fixtureUnchanged: fixtureBefore == fixtureAfter,
            provenanceComplete: fixtureProvenanceIsComplete(fixtureBefore)
                && fixtureProvenanceIsComplete(fixtureAfter),
            adapterRecipeMatches: embeddedAdapterRecipeMatches(
                fixture: fixtureBefore,
                harness: harnessArtifact
            ) && embeddedAdapterRecipeMatches(
                fixture: fixtureAfter,
                harness: harnessArtifact
            ),
            toolchainComplete: fixtureToolchainIsComplete(fixtureBefore)
                && fixtureToolchainIsComplete(fixtureAfter),
            publicArgumentsSafe: app.argumentTemplates.allSatisfy(isPublicArgumentTemplate),
            sampleHostConditionsAcceptable: appSamples.allSatisfy {
                $0.hostConditionBeforeLaunch.isNominalForPublication
                    && $0.hostConditionAfterCleanup.isNominalForPublication
            }
        )
    }
    let publication = publicationAssessment(
        requested: options.publish,
        facts: PublicationFacts(
            runsPerApp: options.runsPerApp,
            stableCoalitionObservations: options.stableObservations,
            stableCoalitionWindowMilliseconds: options.stableWindowMilliseconds,
            rssToleranceKiB: options.rssToleranceKiB,
            repositoryBefore: repositoryBefore.metadata,
            repositoryAfter: repositoryAfter.metadata,
            harnessProvenanceComplete: harnessProvenanceIsComplete(harnessArtifact),
            canonicalHTML: canonicalHTML,
            publicationOutputProvided: outputURL != nil,
            outputWillPreserveCleanTree: outputURL != nil,
            hostBefore: hostBefore,
            hostAfter: hostAfter,
            aborted: abortedReason != nil,
            foregroundSessionProofComplete: foregroundSessionProofComplete,
            recordedSampleCount: samples.count,
            foregroundSessionStartedSampleCount: foregroundSessionEvidence.startedSampleCount,
            foregroundSessionExactRestorationCount: foregroundSessionEvidence.exactRestorationCount,
            foregroundSessionFinishedSampleCount: foregroundSessionEvidence.finishedSampleCount,
            arms: armFacts
        )
    )
    let document = BenchmarkDocument(
        schemaVersion: harnessSchemaVersion,
        harnessVersion: harnessVersion,
        startedAtUtc: ISO8601DateFormatter().string(from: started),
        finishedAtUtc: ISO8601DateFormatter().string(from: Date()),
        repository: RepositoryTransitionMetadata(
            before: repositoryBefore.metadata,
            after: repositoryAfter.metadata
        ),
        harnessArtifact: harnessArtifact,
        hostBefore: hostBefore,
        hostAfter: hostAfter,
        fixtures: fixtureMetadataBefore,
        protocolMetadata: ProtocolMetadata(
            listener: "127.0.0.1:ephemeral",
            htmlFileName: "hello.html",
            htmlSha256: sha256Hex(html),
            tokenTransports: ["URL path/query", "KELD_BENCH_TOKEN environment"],
            completionSignal: "double-rAF paint-opportunity proxy: GET /beacon.gif after nested requestAnimationFrame (not compositor completion or display scanout)",
            launchApi: "NSWorkspace.openApplication + createsNewApplicationInstance",
            coalitionApi: "generation-bound proc info launch ownership; launchctl resource-coalition verification; coalition_info_pid_list plus resource-usage lifecycle counters bracketing one ps RSS observation; process unique-ID revalidation; audit-token generation-bound cleanup"
        ),
        configuration: MeasurementConfiguration(
            runsPerApp: options.runsPerApp,
            appOrder: "round-robin with rotating first app",
            sampleTimeoutSeconds: options.timeoutSeconds,
            cleanupTimeoutSeconds: options.cleanupTimeoutSeconds,
            stableCoalitionObservations: options.stableObservations,
            stableCoalitionWindowMilliseconds: options.stableWindowMilliseconds,
            rssToleranceKiB: options.rssToleranceKiB,
            observationPollMilliseconds: 50,
            cacheState: "fresh application process; OS and WebKit caches uncontrolled (not a cold-cache claim)"
        ),
        foregroundSession: foregroundSessionEvidence,
        samples: samples,
        summaries: summarize(apps: options.apps, samples: samples),
        abortedReason: abortedReason,
        publication: publication
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let json = try encoder.encode(document)
    try emitBenchmarkJSON(json, outputDestination: outputURL)
    return BenchmarkOutcome(
        measurementSucceeded: benchmarkMeasurementSucceeded(
            abortedReason: abortedReason,
            foregroundSessionProofComplete: foregroundSessionProofComplete,
            samplesContainFailure: samples.contains(where: { $0.status != "ok" })
        ),
        publicationEligible: publication.eligible
    )
}

#if FOREGROUND_STATE_SELF_TEST
@main
struct ForegroundStateTestMain {
    @MainActor
    static func main() {
        do {
            try validateForegroundTransitionContract()
            try validateForegroundPublicationPolicyContract()
            FileHandle.standardError.write(
                Data("foreground-state self-test: all controls passed\n".utf8)
            )
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }
}
#else
@main
struct HarnessMain {
    static func main() async {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            if options.showHelp {
                printUsage()
                return
            }
            let htmlURL = try resolveHTMLURL(options.htmlURL)
            let html = try Data(contentsOf: htmlURL)
            if options.selfTest {
                try await runSelfTests(html: html)
                return
            }
            let outcome = try await runBenchmark(options: options, htmlURL: htmlURL, html: html)
            if !outcome.measurementSucceeded { Darwin.exit(2) }
            if options.publish, !outcome.publicationEligible { Darwin.exit(3) }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }
}
#endif
