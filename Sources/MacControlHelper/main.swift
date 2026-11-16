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
    // Match wall-clock-independent deadlines; manual overrides must not survive a clock adjustment.
    var monotonicNow: Date { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) }

    init(authorizedUID: uid_t) {
        self.authorizedUID = authorizedUID
        do { smc = try SMCConnection() }
        catch { connectionError = error.localizedDescription }
    }

    func response(ok: Bool, _ message: String) -> HelperResponse {
        HelperResponse(ok: ok, message: message, manualFanIDs: leases.fanIDs)
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
            guard let smc else { return response(ok: false, "SMC is unavailable: \(connectionError ?? "Unknown error")") }
            switch request.command {
            case .status:
                return response(ok: true, "Helper ready. Manual control leases expire after 12 seconds.")
            case .set:
                let fanID = request.fanID!
                let rpm = request.rpm!
                guard let fan = smc.fans().first(where: { $0.id == fanID }) else {
                    return response(ok: false, "This fan does not exist or is unavailable.")
                }
                try FanControlPolicy.validateSet(requestedRPM: rpm, minimumRPM: fan.minRPM, maximumRPM: fan.maxRPM,
                                                 temperatures: smc.temperatures().map(\.celsius))
                // Track before writing so any partial SMC failure remains subject to cleanup.
                if !leases.fanIDs.contains(fanID) { try persistOwnership(leases.fanIDs + [fanID]) }
                leases.renew(fanID: fanID, now: monotonicNow)
                do { try smc.setFan(id: fanID, rpm: rpm) }
                catch {
                    try? smc.restoreAutomatic(fanID: fanID)
                    throw error
                }
                return response(ok: true, "Fan \(fanID + 1) set to \(Int(rpm)) RPM; lease renewed.")
            case .automatic:
                if let fanID = request.fanID {
                    guard smc.fans().contains(where: { $0.id == fanID }) else {
                        return response(ok: false, "This fan does not exist or is unavailable.")
                    }
                    try smc.restoreAutomatic(fanID: fanID)
                    leases.remove(fanID: fanID)
                    try persistOwnership(leases.fanIDs)
                } else {
                    try smc.restoreAllAutomatic()
                    leases.removeAll()
                    try persistOwnership([])
                }
                return response(ok: true, "System automatic control restored.")
            }
        } catch { return response(ok: false, error.localizedDescription) }
    }

    func enforceLeases() {
        guard !leases.fanIDs.isEmpty, let smc else { return }
        let temperatures = smc.temperatures().map(\.celsius)
        let unsafe = temperatures.isEmpty || temperatures.contains { !$0.isFinite || $0 <= 0 || $0 >= FanControlPolicy.maximumTemperature }
        let restoreIDs = unsafe ? leases.fanIDs : leases.expired(at: monotonicNow)
        for id in restoreIDs {
            do {
                try smc.restoreAutomatic(fanID: id)
                leases.remove(fanID: id)
            } catch {
                // Keep failed restorations in the book and retry on the next watchdog tick.
                fputs("Automatic restore failed for fan \(id): \(error.localizedDescription)\n", stderr)
            }
        }
        if !restoreIDs.isEmpty {
            do { try persistOwnership(leases.fanIDs) }
            catch { fputs("Control recovery journal update failed: \(error.localizedDescription)\n", stderr) }
        }
    }

    func cleanup() {
        guard let smc else { return }
        // Only restore overrides created by this helper; do not interfere with another utility.
        for id in leases.fanIDs {
            do {
                try smc.restoreAutomatic(fanID: id)
                leases.remove(fanID: id)
            } catch { fputs("Shutdown restore failed for fan \(id): \(error.localizedDescription)\n", stderr) }
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
                    let reply = response(ok: false, "Invalid helper request: \(error.localizedDescription)")
                    try? FanControlSocket.send(JSONEncoder().encode(reply), to: client)
                }
            }
            close(client)
        }
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--help") {
    print("Mac Control Pro fan helper\nUsage: MacControlHelper --uid USER_ID\n       MacControlHelper --self-test\nRuns as root under launchd. Only the configured UID or root can connect.")
    exit(0)
}
if arguments.contains("--self-test") {
    do {
        let request = FanRequest(command: .set, fanID: 0, rpm: 2000)
        try JSONDecoder().decode(FanRequest.self, from: JSONEncoder().encode(request)).validate()
        try FanControlPolicy.validateSet(requestedRPM: 2000, minimumRPM: 1000, maximumRPM: 6000, temperatures: [45])
        print("Helper protocol and control policy self-test passed. No hardware was accessed or changed.")
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
