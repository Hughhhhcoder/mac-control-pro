import Darwin
import Foundation

public enum FanControlSocket {
    public static let path = "/var/run/mac-control-pro/control.sock"
    public static let maximumMessageBytes = 4096
    public static let timeout: TimeInterval = 2

    public static func address(path: String = path) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw FanControlError.transport("Socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    public static func configureTimeout(_ descriptor: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        withUnsafePointer(to: &timeout) {
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func send(_ data: Data, to descriptor: Int32) throws {
        guard data.count <= maximumMessageBytes else { throw FanControlError.transport("Message exceeds 4096 bytes.") }
        var frame = data; frame.append(10)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw FanControlError.connectionTimeout("Sending the helper message timed out.") }
                var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&item, 1, Int32(max(1, remaining * 1000)))
                if ready < 0, errno == EINTR { continue }
                guard ready > 0, (item.revents & Int16(POLLOUT)) != 0 else { throw FanControlError.transport("The helper connection closed or timed out while sending.") }
                let written = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, MSG_DONTWAIT)
                if written < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard written > 0 else { throw FanControlError.transport("Could not send the helper message.") }
                offset += written
            }
        }
    }

    public static func receive(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while result.count <= maximumMessageBytes {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw FanControlError.connectionTimeout("The helper response timed out.") }
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, Int32(max(1, remaining * 1000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, (item.revents & Int16(POLLIN)) != 0 else { throw FanControlError.transport("The helper connection closed or timed out.") }
            let count = Darwin.recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
            if count < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw FanControlError.transport("The helper connection closed before returning a complete response.") }
            if let delimiter = buffer.prefix(count).firstIndex(of: 10) {
                result.append(contentsOf: buffer[..<delimiter])
                guard result.count <= maximumMessageBytes else { break }
                return result
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        throw FanControlError.transport("Message exceeds 4096 bytes.")
    }

    static func connect(_ descriptor: Int32, address: inout sockaddr_un) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw FanControlError.transport("Could not configure the helper connection.") }
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected == 0 { return }
        let initialError = errno
        guard [EINPROGRESS, EAGAIN, EWOULDBLOCK].contains(initialError) else { throw connectError(initialError) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw FanControlError.connectionTimeout("Connecting to the fan helper timed out. It may be busy or stopped.") }
            var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&item, 1, Int32(max(1, remaining * 1000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw FanControlError.connectionTimeout("Connecting to the fan helper timed out.") }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw FanControlError.transport("Could not inspect the helper connection.") }
            guard error == 0 else { throw connectError(error) }
            guard (item.revents & Int16(POLLOUT)) != 0 else { throw FanControlError.unavailable("The fan helper closed the connection. Reinstall the current helper.") }
            return
        }
    }

    private static func connectError(_ code: Int32) -> FanControlError {
        switch code {
        case ENOENT: return .helperNotInstalled("The fan helper is not installed. Open Settings and install the fan helper on this Mac.")
        case EACCES, EPERM: return .wrongUser("The installed fan helper belongs to another macOS account. Reinstall it while signed in to the account that will control fans.")
        case ECONNREFUSED: return .unavailable("The fan helper is not running. Reinstall the current helper from this app's installer.")
        default: return .transport("Could not connect to the fan helper (system error \(code)). Reinstall the current helper if this persists.")
        }
    }
}

/// A stable instance represents one app or CLI control session. Keep it for all renewals.
public struct HelperClient: Sendable {
    public let sessionID: String
    public init(sessionID: String = UUID().uuidString) { self.sessionID = sessionID }

    public func status() throws -> HelperResponse { try perform(FanRequest(command: .status)) }
    public func set(fanID: Int, rpm: Double) throws -> HelperResponse {
        // A 0.1.x helper would ignore unknown fields on .set. Check its status before
        // issuing the command, rather than accidentally writing through the old protocol.
        try requireCurrentProtocol(try status())
        return try perform(FanRequest(command: .set, fanID: fanID, rpm: rpm, leaseID: sessionID))
    }
    public func renew(fanID: Int, rpm: Double) throws -> HelperResponse {
        let reply = try perform(FanRequest(command: .renew, fanID: fanID, rpm: rpm, leaseID: sessionID))
        try requireCurrentProtocol(reply)
        return reply
    }
    public func release(fanID: Int? = nil) throws -> HelperResponse {
        let reply = try perform(FanRequest(command: .release, fanID: fanID, leaseID: sessionID))
        try requireCurrentProtocol(reply)
        return reply
    }
    public func automatic(fanID: Int? = nil) throws -> HelperResponse { try perform(FanRequest(command: .automatic, fanID: fanID)) }

    private func requireCurrentProtocol(_ response: HelperResponse) throws {
        guard response.supportsSafeControl else {
            let found = response.helperVersion ?? "0.1.x / unknown"
            throw FanControlError.upgradeRequired("The installed fan helper (\(found)) does not support this app's safe control protocol. Install the current app and fan helper together on this Mac.")
        }
    }

    private func perform(_ request: FanRequest) throws -> HelperResponse {
        try request.validate()
        var info = stat()
        if lstat(FanControlSocket.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw FanControlError.untrustedHelper("The fan helper path is not a socket. Reinstall the helper; do not replace this file manually.") }
            guard getuid() == 0 || info.st_uid == getuid() || info.st_uid == 0 else { throw FanControlError.wrongUser("The installed fan helper is assigned to another macOS account. Reinstall it for your account.") }
        } else if errno == ENOENT {
            throw FanControlError.helperNotInstalled("The fan helper is not installed on this Mac. Install it from Settings before applying a fan speed.")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FanControlError.transport("Could not create the helper socket.") }
        defer { close(descriptor) }
        FanControlSocket.configureTimeout(descriptor)
        var address = try FanControlSocket.address()
        try FanControlSocket.connect(descriptor, address: &address)
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == 0 else { throw FanControlError.untrustedHelper("Refusing a fan helper that is not running as root.") }
        try FanControlSocket.send(JSONEncoder().encode(request), to: descriptor)
        do { return try JSONDecoder().decode(HelperResponse.self, from: FanControlSocket.receive(from: descriptor)) }
        catch let error as FanControlError { throw error }
        catch { throw FanControlError.transport("The helper returned an invalid response. Install the app and its matching helper together. \(error.localizedDescription)") }
    }
}
