import Darwin
import Foundation
import MacControlCore

private var requestedStop: sig_atomic_t = 0

private func stopHandler(_ signal: Int32) { requestedStop = 1 }

private final class FanHelper {
    private let journalPath = "/var/run/mac-control-pro/leases.json"
    let authorizedUID: uid_t
    var smc: SMCConnection?
    var connectionError: String?
    var leases = FanLeaseBook()
    var pendingFanIDs = Set<Int>()
    var recoveryRequiredFanIDs = Set<Int>()
    var lastRecovery: HelperControlBlock?
    private var lastConnectionAttempt: TimeInterval = -.infinity
    private let hardwareModel = FanHelper.modelIdentifier()
    // Match wall-clock-independent deadlines; manual overrides must not survive a clock adjustment.
    var monotonicNow: Date { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) }

    init(authorizedUID: uid_t) {
        self.authorizedUID = authorizedUID
        ensureConnection()
    }

    private static func modelIdentifier() -> String {
        var length = 0
        guard sysctlbyname("hw.model", nil, &length, nil, 0) == 0, length > 0, length < 256 else { return "Unknown" }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("hw.model", &bytes, &length, nil, 0) == 0 else { return "Unknown" }
        return String(cString: bytes)
    }

    private var thermalPressure: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }

    private func ensureConnection() {
        let now = ProcessInfo.processInfo.systemUptime
        guard smc == nil, now - lastConnectionAttempt >= 5 else { return }
        lastConnectionAttempt = now
        do { smc = try SMCConnection(); connectionError = nil }
        catch { connectionError = error.localizedDescription }
    }

    func response(ok: Bool, _ message: String, errorCode: HelperErrorCode? = nil,
                  state: HelperApplicationState? = nil, requestedRPM: Double? = nil,
                  confirmedTargetRPM: Double? = nil, retryAfter: Double? = nil,
                  block: HelperControlBlock? = nil) -> HelperResponse {
        HelperResponse(ok: ok, message: message, manualFanIDs: leases.fanIDs,
                       protocolVersion: FanControlProtocol.currentVersion, helperVersion: FanControlProtocol.helperVersion,
                       authorizedUID: authorizedUID, smcAvailable: smc != nil, hardwareModel: hardwareModel,
                       controlBlockReason: block?.message, controlBlockCode: block?.code,
                       temperatureLimitCelsius: FanControlPolicy.maximumTemperature,
                       requestedRPM: requestedRPM, confirmedTargetRPM: confirmedTargetRPM,
                       errorCode: errorCode, applicationState: state, retryAfterSeconds: retryAfter,
                       pendingFanIDs: Array(pendingFanIDs), lastRecoveryReason: lastRecovery?.message,
                       lastRecoveryCode: lastRecovery?.code)
    }

    private func statusResponse() -> HelperResponse {
        ensureConnection()
        guard let smc else {
            var reply = response(ok: false, "The helper is installed, but SMC access is unavailable: \(connectionError ?? "Unknown error"). It will retry automatically.", errorCode: .smcUnavailable, state: .blocked)
            reply.canControl = false; reply.controlBlockCode = .smcUnavailable; reply.controlBlockReason = reply.message
            reply.fanCapabilities = []
            return reply
        }
        let fans = smc.fans()
        let temperatures = smc.temperatures().map(\.celsius)
        let capabilities = fans.map { fan in
            HelperFanCapability(id: fan.id, canControl: fan.canRequestControl,
                                issue: fan.controlIssue.map { String($0.prefix(160)) }, minRPM: fan.minRPM, maxRPM: fan.maxRPM,
                                modeKey: fan.modeKey, targetKey: fan.targetKey)
        }
        let block: HelperControlBlock?
        if let guardBlock = FanControlPolicy.guardFailure(temperatures: temperatures, thermalPressure: thermalPressure) { block = guardBlock }
        else if !recoveryRequiredFanIDs.isEmpty { block = .init(code: .recoveryFailed, message: "Automatic recovery is still in progress. New control requests are blocked until recovery is confirmed.") }
        else if fans.isEmpty { block = .init(code: .fanUnavailable, message: "No fan control records are exposed by this Mac. Monitoring remains available.") }
        else if !capabilities.contains(where: \.canControl) { block = .init(code: .fanReadOnly, message: "Fan readings are available, but this firmware does not expose all required control keys and bounds.") }
        else { block = nil }
        var reply = response(ok: true, "Fan helper connected. Control protocol \(FanControlProtocol.currentVersion); leases expire after 12 seconds.",
                             state: block != nil ? .blocked : pendingFanIDs.isEmpty ? (leases.fanIDs.isEmpty ? .automatic : .applied) : .pending, block: block)
        reply.fanCapabilities = capabilities; reply.canControl = block == nil
        reply.hottestTemperatureCelsius = temperatures.max()
        return reply
    }

    /// Persist ownership before hardware writes so launchd restart can recover a crashed helper.
    private func persistOwnership(_ ids: [Int]) throws {
        let temporary = "/var/run/mac-control-pro/.leases-\(UUID().uuidString).tmp"
        let file = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw FanControlError.transport("Cannot create control recovery journal.") }
        defer { close(file); unlink(temporary) }
        let data = try JSONEncoder().encode(Array(Set(ids)).sorted())
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw FanControlError.transport("Cannot write control recovery journal.") }
                offset += written
            }
        }
        guard fsync(file) == 0, rename(temporary, journalPath) == 0 else {
            throw FanControlError.transport("Cannot save control recovery journal.")
        }
    }

    private func recoverOwnership() throws {
        let file = open(journalPath, O_RDONLY | O_NOFOLLOW)
        if file < 0, errno == ENOENT { return }
        guard file >= 0 else { throw FanControlError.transport("Cannot open control recovery journal.") }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0, (info.st_mode & 0o022) == 0,
              info.st_size > 0, info.st_size <= 4096 else {
            throw FanControlError.transport("Control recovery journal must be a bounded, root-owned regular file.")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        while offset < bytes.count {
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            }
            if received < 0, errno == EINTR { continue }
            guard received > 0 else { throw FanControlError.transport("Cannot read control recovery journal.") }
            offset += received
        }
        let ids = try JSONDecoder().decode([Int].self, from: Data(bytes))
        guard ids.count <= 16, ids.allSatisfy({ (0..<16).contains($0) }) else {
            throw FanControlError.transport("Invalid fan IDs in control recovery journal.")
        }
        let expired = monotonicNow.addingTimeInterval(-FanLeaseBook.lifetime)
        for id in ids { leases.renew(fanID: id, now: expired) }
        enforceLeases()
    }

    func handle(_ request: FanRequest) -> HelperResponse {
        do {
            try request.validate()
            if request.command == .status { return statusResponse() }
            if request.command == .set || request.command == .renew || request.command == .release { try request.validateForControl() }
            if request.command == .release, leases.ownedFanIDs(ownerID: request.leaseID!, fanID: request.fanID).isEmpty {
                return response(ok: true, "This session owns no matching fan controls. No hardware state was changed.", state: .released)
            }
            ensureConnection()
            guard let smc else { return response(ok: false, "The helper is installed, but SMC access is unavailable: \(connectionError ?? "Unknown error")", errorCode: .smcUnavailable, state: .blocked) }
            switch request.command {
            case .status:
                return statusResponse()
            case .set, .renew:
                let fanID = request.fanID!, rpm = request.rpm!, owner = request.leaseID!
                var nextLeases = leases
                if request.command == .renew { try nextLeases.renewExisting(fanID: fanID, ownerID: owner, now: monotonicNow) }
                else { try nextLeases.acquire(fanID: fanID, ownerID: owner, now: monotonicNow) }
                guard !recoveryRequiredFanIDs.contains(fanID) else {
                    return response(ok: false, "Automatic recovery for fan \(fanID + 1) is still in progress. Control cannot resume until automatic mode is confirmed.", errorCode: .recoveryFailed, state: .blocked)
                }
                guard let fan = smc.fans().first(where: { $0.id == fanID }) else {
                    return response(ok: false, "This fan is not reported by this Mac.", errorCode: .fanUnavailable, state: .blocked)
                }
                guard fan.canRequestControl, let minimum = fan.minRPM, let maximum = fan.maxRPM else {
                    return response(ok: false, fan.controlIssue ?? "This fan is available for monitoring only.", errorCode: .fanReadOnly, state: .blocked)
                }
                let temperatures = smc.temperatures().map(\.celsius)
                if let block = FanControlPolicy.guardFailure(temperatures: temperatures, thermalPressure: thermalPressure) {
                    return response(ok: false, block.message, errorCode: block.code, state: .blocked, block: block)
                }
                try FanControlPolicy.validateSet(requestedRPM: rpm, minimumRPM: minimum, maximumRPM: maximum, temperatures: temperatures)
                // Check the ownership contract before any write. Persist new ownership before
                // the SMC change, so a partial write remains recoverable after a helper crash.
                if !leases.fanIDs.contains(fanID) { try persistOwnership(nextLeases.fanIDs) }
                leases = nextLeases
                do {
                    switch try smc.setFan(id: fanID, rpm: rpm) {
                    case .pending(let retryAfter, let message):
                        pendingFanIDs.insert(fanID)
                        return response(ok: true, message, state: .pending, requestedRPM: rpm, retryAfter: retryAfter)
                    case .applied:
                        let confirmed = smc.fans().first(where: { $0.id == fanID })
                        guard confirmed?.isManual == true else {
                            throw SMCError.verificationFailed(confirmed?.modeKey ?? "fan \(fanID + 1) manual mode")
                        }
                        guard let target = confirmed?.targetRPM, abs(target - rpm) < 1 else {
                            throw SMCError.writeNotConfirmed(key: "fan \(fanID + 1) target", requested: rpm, observed: confirmed?.targetRPM)
                        }
                        pendingFanIDs.remove(fanID); lastRecovery = nil
                        return response(ok: true, "Fan \(fanID + 1) target accepted. Actual RPM is reported separately and may take time to settle.",
                                        state: .applied, requestedRPM: rpm, confirmedTargetRPM: target)
                    }
                } catch {
                    let writeMessage = error.localizedDescription
                    do {
                        try smc.restoreAutomatic(fanID: fanID)
                        leases.remove(fanID: fanID); pendingFanIDs.remove(fanID); recoveryRequiredFanIDs.remove(fanID)
                        try persistOwnership(leases.fanIDs)
                        return response(ok: false, "Fan control failed: \(writeMessage) Automatic mode was restored.", errorCode: .writeFailed, state: .automatic, requestedRPM: rpm)
                    } catch {
                        if leases.fanIDs.contains(fanID) { recoveryRequiredFanIDs.insert(fanID) }
                        return response(ok: false, "Fan control failed: \(writeMessage) Automatic recovery also failed: \(error.localizedDescription). The helper will keep retrying recovery.", errorCode: .recoveryFailed, state: .blocked, requestedRPM: rpm)
                    }
                }
            case .release:
                let owned = leases.ownedFanIDs(ownerID: request.leaseID!, fanID: request.fanID)
                var failures: [String] = []
                for fanID in owned {
                    do {
                        try smc.restoreAutomatic(fanID: fanID)
                        leases.remove(fanID: fanID); pendingFanIDs.remove(fanID); recoveryRequiredFanIDs.remove(fanID)
                    } catch {
                        recoveryRequiredFanIDs.insert(fanID)
                        failures.append("Fan \(fanID + 1): \(error.localizedDescription)")
                    }
                }
                do { try persistOwnership(leases.fanIDs) }
                catch { failures.append("Recovery journal: \(error.localizedDescription)") }
                if !failures.isEmpty {
                    return response(ok: false, "Some controls owned by this session could not be released: " + failures.prefix(3).joined(separator: "; "), errorCode: .recoveryFailed, state: .blocked)
                }
                return response(ok: true, "This session's fan controls were released to system automatic mode. Other sessions were not changed.", state: .released)
            case .automatic:
                if let fanID = request.fanID {
                    do { try smc.restoreAutomatic(fanID: fanID) }
                    catch {
                        if leases.fanIDs.contains(fanID) { recoveryRequiredFanIDs.insert(fanID) }
                        throw error
                    }
                    leases.remove(fanID: fanID); pendingFanIDs.remove(fanID); recoveryRequiredFanIDs.remove(fanID)
                } else {
                    do { try smc.restoreAllAutomatic() }
                    catch {
                        recoveryRequiredFanIDs.formUnion(leases.fanIDs)
                        throw error
                    }
                    leases.removeAll(); pendingFanIDs.removeAll(); recoveryRequiredFanIDs.removeAll()
                }
                try persistOwnership(leases.fanIDs); lastRecovery = nil
                return response(ok: true, "System automatic control was restored.", state: .automatic)
            }
        } catch let error as FanControlError {
            let reason = error.code == .leaseExpired ? lastRecovery?.message : nil
            return response(ok: false, reason.map { "\(error.localizedDescription) \($0)" } ?? error.localizedDescription,
                            errorCode: error.code, state: .blocked)
        } catch {
            return response(ok: false, error.localizedDescription,
                            errorCode: request.command == .automatic || request.command == .release ? .recoveryFailed : .writeFailed, state: .blocked)
        }
    }

    func enforceLeases() {
        ensureConnection()
        guard !leases.fanIDs.isEmpty, let smc else { return }
        let temperatures = smc.temperatures().map(\.celsius)
        let block = FanControlPolicy.guardFailure(temperatures: temperatures, thermalPressure: thermalPressure)
        let fans = smc.fans()
        var changed = false
        for id in leases.fanIDs {
            let fan = fans.first(where: { $0.id == id })
            // Release a global unlock before clearing ownership after firmware reclaims
            // a per-fan mode. Failed restoration must remain in the recovery journal.
            let reclaimed = block == nil && !pendingFanIDs.contains(id) && [0, 3].contains(fan?.modeRawValue ?? -1)
            let expired = !leases.isActive(fanID: id, now: monotonicNow)
            let missing = fan == nil || fan?.canRequestControl == false
            let recoveryRequired = recoveryRequiredFanIDs.contains(id)
            guard block != nil || reclaimed || expired || missing || recoveryRequired else { continue }
            do {
                try smc.restoreAutomatic(fanID: id)
                leases.remove(fanID: id); pendingFanIDs.remove(id); recoveryRequiredFanIDs.remove(id); changed = true
                lastRecovery = block ?? (missing ? .init(code: .fanReadOnly, message: "Fan \(id + 1) lost readable control prerequisites; automatic mode was restored.") : .init(code: .leaseExpired, message: recoveryRequired ? "Automatic recovery for fan \(id + 1) was confirmed; the previous control session was ended." : reclaimed ? "Firmware returned fan \(id + 1) to system control; automatic recovery was confirmed." : "The client stopped renewing fan \(id + 1); automatic mode was restored."))
            } catch {
                recoveryRequiredFanIDs.insert(id)
                lastRecovery = .init(code: .recoveryFailed, message: "Automatic recovery for fan \(id + 1) failed and will be retried: \(error.localizedDescription)")
                fputs(lastRecovery!.message + "\n", stderr)
            }
        }
        if changed {
            do { try persistOwnership(leases.fanIDs) }
            catch { fputs("Control recovery journal update failed: \(error.localizedDescription)\n", stderr) }
        }
    }

    func cleanup() {
        guard let smc else { return }
        for id in leases.fanIDs {
            do {
                try smc.restoreAutomatic(fanID: id)
                leases.remove(fanID: id); pendingFanIDs.remove(id); recoveryRequiredFanIDs.remove(id)
            } catch {
                recoveryRequiredFanIDs.insert(id)
                fputs("Shutdown restore failed for fan \(id): \(error.localizedDescription)\n", stderr)
            }
        }
        do { try persistOwnership(leases.fanIDs) }
        catch { fputs("Shutdown recovery journal update failed: \(error.localizedDescription)\n", stderr) }
    }

    func serve() throws {
        let directory = "/var/run/mac-control-pro"
        var info = stat()
        if lstat(directory, &info) != 0 {
            guard errno == ENOENT, mkdir(directory, 0o755) == 0 else {
                throw FanControlError.transport("Cannot create helper runtime directory.")
            }
            guard lstat(directory, &info) == 0 else { throw FanControlError.transport("Cannot inspect helper runtime directory.") }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0, (info.st_mode & 0o022) == 0 else {
            throw FanControlError.transport("Helper runtime directory must be a root-owned directory without group or public write permission.")
        }
        try recoverOwnership()
        defer { cleanup() }
        let path = FanControlSocket.path
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK,
                  existing.st_uid == 0 || existing.st_uid == authorizedUID else {
                throw FanControlError.transport("Refusing to replace an unexpected file at the socket path.")
            }
            guard unlink(path) == 0 else { throw FanControlError.transport("Cannot replace stale helper socket.") }
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FanControlError.transport("Cannot create server socket.") }
        defer { close(descriptor); unlink(path) }
        var address = try FanControlSocket.address()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chown(path, authorizedUID, gid_t.max) == 0,
              chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            throw FanControlError.transport("Cannot bind or secure helper socket.")
        }
        signal(SIGTERM, stopHandler)
        signal(SIGINT, stopHandler)
        signal(SIGHUP, stopHandler)
        signal(SIGPIPE, SIG_IGN)
        while requestedStop == 0 {
            enforceLeases()
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 500)
            if ready <= 0 { continue }
            guard (item.revents & Int16(POLLIN)) != 0 else { continue }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { continue }
            FanControlSocket.configureTimeout(client)
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            if getpeereid(client, &peerUID, &peerGID) == 0, peerUID == authorizedUID || peerUID == 0 {
                do {
                    let data = try FanControlSocket.receive(from: client)
                    let request = try JSONDecoder().decode(FanRequest.self, from: data)
                    enforceLeases()
                    let reply = handle(request)
                    try FanControlSocket.send(JSONEncoder().encode(reply), to: client)
                } catch {
                    let reply = response(ok: false, "Invalid helper request: \(error.localizedDescription)", errorCode: .invalidRequest, state: .blocked)
                    try? FanControlSocket.send(JSONEncoder().encode(reply), to: client)
                }
            }
            close(client)
        }
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--version") {
    print("MacControlHelper \(FanControlProtocol.helperVersion) (control protocol \(FanControlProtocol.currentVersion))")
    exit(0)
}
if arguments.contains("--help") {
    print("Mac Control Pro fan helper\nUsage: MacControlHelper --uid USER_ID\n       MacControlHelper --self-test\n       MacControlHelper --version\nRuns as root under launchd. Only the configured UID or root can connect.")
    exit(0)
}
if arguments.contains("--self-test") {
    do {
        let owner = UUID().uuidString
        let request = FanRequest(command: .set, fanID: 0, rpm: 2000, leaseID: owner)
        try JSONDecoder().decode(FanRequest.self, from: JSONEncoder().encode(request)).validateForControl()
        var leases = FanLeaseBook()
        try leases.acquire(fanID: 0, ownerID: owner)
        try leases.renewExisting(fanID: 0, ownerID: owner)
        guard leases.ownedFanIDs(ownerID: UUID().uuidString).isEmpty, leases.ownedFanIDs(ownerID: owner) == [0] else {
            throw FanControlError.invalidRequest("Lease ownership self-test failed.")
        }
        try FanControlPolicy.validateSet(requestedRPM: 2000, minimumRPM: 1000, maximumRPM: 6000, temperatures: [45])
        print("Helper \(FanControlProtocol.helperVersion), protocol \(FanControlProtocol.currentVersion), lease ownership and control policy self-test passed. No hardware was accessed or changed.")
        exit(0)
    } catch { fputs("Self-test failed: \(error)\n", stderr); exit(1) }
}
guard arguments.count == 3, arguments[1] == "--uid", let uid = UInt32(arguments[2]), uid >= 501 else {
    fputs("Usage: MacControlHelper --uid USER_ID (USER_ID must be 501 or greater)\n", stderr)
    exit(64)
}
guard geteuid() == 0 else {
    fputs("The fan helper must be installed as a root launch daemon. See docs/HELPER.md.\n", stderr)
    exit(77)
}
do { try FanHelper(authorizedUID: uid).serve() }
catch { fputs("Helper failed: \(error.localizedDescription)\n", stderr); exit(1) }
