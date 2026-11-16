import Darwin
import Foundation

public enum FanControlSocket {
    public static let path = "/var/run/mac-control-pro/control.sock"
    public static let maximumMessageBytes = 4096

    public static func address(path: String = path) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw FanControlError.transport("Socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
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
        var frame = data
        frame.append(10)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw FanControlError.transport("Could not send helper message.") }
                offset += written
            }
        }
    }

    public static func receive(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while result.count <= maximumMessageBytes {
            // An absolute deadline also limits slow clients that keep sending one byte.
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw FanControlError.transport("Helper message timed out.") }
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, Int32(max(1, remaining * 1000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, (item.revents & Int16(POLLIN)) != 0 else {
                throw FanControlError.transport("Helper connection closed or timed out.")
            }
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw FanControlError.transport("Helper connection closed or timed out.") }
            if let delimiter = buffer.prefix(count).firstIndex(of: 10) {
                result.append(contentsOf: buffer[..<delimiter])
                guard result.count <= maximumMessageBytes else { break }
                return result
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        throw FanControlError.transport("Message exceeds 4096 bytes.")
    }
}

/// Blocking local IPC. Call from a background queue, never a SwiftUI render callback.
public struct HelperClient: Sendable {
    public init() {}

    public func status() throws -> HelperResponse { try perform(FanRequest(command: .status)) }
    public func set(fanID: Int, rpm: Double) throws -> HelperResponse {
        try perform(FanRequest(command: .set, fanID: fanID, rpm: rpm))
    }
    public func automatic(fanID: Int? = nil) throws -> HelperResponse {
        try perform(FanRequest(command: .automatic, fanID: fanID))
    }

    private func perform(_ request: FanRequest) throws -> HelperResponse {
        try request.validate()
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FanControlError.transport("Could not create helper socket.") }
        defer { close(descriptor) }
        FanControlSocket.configureTimeout(descriptor)
        var address = try FanControlSocket.address()
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw FanControlError.unavailable("Fan helper is not installed, is unavailable, or belongs to another user. See Settings → Fan control.")
        }
        // A socket with a copied name is insufficient: the server must actually be root.
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == 0 else {
            throw FanControlError.transport("Refusing a helper that is not running as root.")
        }
        try FanControlSocket.send(JSONEncoder().encode(request), to: descriptor)
        return try JSONDecoder().decode(HelperResponse.self, from: FanControlSocket.receive(from: descriptor))
    }
}
