import Darwin
import Foundation

struct ChromiumBridgeEnvelope: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case command
        case event
    }

    let kind: Kind
    let event: KeywayChromiumBridgeEvent?
    let payload: String

    static func command(_ payload: String) -> ChromiumBridgeEnvelope {
        ChromiumBridgeEnvelope(kind: .command, event: nil, payload: payload)
    }

    static func event(_ event: KeywayChromiumBridgeEvent, payload: String) -> ChromiumBridgeEnvelope {
        ChromiumBridgeEnvelope(kind: .event, event: event, payload: payload)
    }
}

final class ChromiumBridgeSocketConnection: @unchecked Sendable {
    private static let maximumPayloadSize = 4 * 1_024 * 1_024

    let peerIdentity: ChromiumBridgePeerIdentity
    private let fileDescriptor: Int32
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var invalidated = false

    init(fileDescriptor: Int32) throws {
        self.fileDescriptor = fileDescriptor
        peerIdentity = try ChromiumBridgeSocket.peerIdentity(fileDescriptor: fileDescriptor)

        var enabled: Int32 = 1
        guard setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw ChromiumBridgeSocket.systemError(operation: "setsockopt(SO_NOSIGPIPE)")
        }
    }

    deinit {
        Darwin.close(fileDescriptor)
    }

    func invalidate() {
        stateLock.lock()
        guard !invalidated else {
            stateLock.unlock()
            return
        }
        invalidated = true
        stateLock.unlock()
        Darwin.shutdown(fileDescriptor, SHUT_RDWR)
    }

    func send(_ envelope: ChromiumBridgeEnvelope) -> Bool {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(envelope)
        } catch {
            preconditionFailure("Chromium bridge encoded an invalid internal envelope: \(error)")
        }
        precondition(
            payload.count <= Self.maximumPayloadSize,
            "Chromium bridge payload exceeds the internal frame limit"
        )

        var frameLength = UInt32(payload.count).bigEndian
        let header = Data(bytes: &frameLength, count: MemoryLayout<UInt32>.size)

        writeLock.lock()
        defer { writeLock.unlock() }
        guard isValid else { return false }
        return writeAll(header) && writeAll(payload)
    }

    func receive() -> ChromiumBridgeEnvelope? {
        guard isValid,
              let header = readExactly(MemoryLayout<UInt32>.size)
        else {
            return nil
        }
        let encodedLength = header.withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        let payloadLength = Int(UInt32(bigEndian: encodedLength))
        guard payloadLength <= Self.maximumPayloadSize,
              let payload = readExactly(payloadLength)
        else {
            return nil
        }
        do {
            return try JSONDecoder().decode(ChromiumBridgeEnvelope.self, from: payload)
        } catch {
            return nil
        }
    }

    private var isValid: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !invalidated
    }

    private func readExactly(_ byteCount: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var offset = 0
        while offset < byteCount {
            let readCount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    fileDescriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    byteCount - offset
                )
            }
            if readCount == 0 {
                return nil
            }
            if readCount < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }
            offset += readCount
        }
        return Data(bytes)
    }

    private func writeAll(_ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { buffer in
            while offset < data.count {
                let writtenCount = Darwin.write(
                    fileDescriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    data.count - offset
                )
                if writtenCount < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                if writtenCount == 0 {
                    return false
                }
                offset += writtenCount
            }
            return true
        }
    }
}

enum ChromiumBridgeSocket {
    static func makeListener(at endpointURL: URL) throws -> Int32 {
        let parentURL = endpointURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: parentURL.path
        )
        if FileManager.default.fileExists(atPath: endpointURL.path) {
            try FileManager.default.removeItem(at: endpointURL)
        }

        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw systemError(operation: "socket")
        }
        do {
            var address = try socketAddress(path: endpointURL.path)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        fileDescriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw systemError(operation: "bind")
            }
            guard chmod(endpointURL.path, 0o600) == 0 else {
                throw systemError(operation: "chmod")
            }
            guard Darwin.listen(fileDescriptor, SOMAXCONN) == 0 else {
                throw systemError(operation: "listen")
            }
            return fileDescriptor
        } catch {
            Darwin.close(fileDescriptor)
            try? FileManager.default.removeItem(at: endpointURL)
            throw error
        }
    }

    static func connect(to endpointURL: URL) throws -> ChromiumBridgeSocketConnection {
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw systemError(operation: "socket")
        }
        do {
            var address = try socketAddress(path: endpointURL.path)
            let connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        fileDescriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard connectResult == 0 else {
                throw systemError(operation: "connect")
            }
            return try ChromiumBridgeSocketConnection(fileDescriptor: fileDescriptor)
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    static func accept(listener: Int32) throws -> ChromiumBridgeSocketConnection {
        let fileDescriptor = Darwin.accept(listener, nil, nil)
        guard fileDescriptor >= 0 else {
            throw systemError(operation: "accept")
        }
        do {
            return try ChromiumBridgeSocketConnection(fileDescriptor: fileDescriptor)
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    static func peerIdentity(fileDescriptor: Int32) throws -> ChromiumBridgePeerIdentity {
        var processIdentifier: pid_t = 0
        var processIdentifierByteCount = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            fileDescriptor,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &processIdentifier,
            &processIdentifierByteCount
        ) == 0 else {
            throw systemError(operation: "getsockopt(LOCAL_PEERPID)")
        }

        var auditToken = audit_token_t()
        var auditTokenByteCount = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(
            fileDescriptor,
            SOL_LOCAL,
            LOCAL_PEERTOKEN,
            &auditToken,
            &auditTokenByteCount
        ) == 0 else {
            throw systemError(operation: "getsockopt(LOCAL_PEERTOKEN)")
        }
        let auditTokenData = withUnsafeBytes(of: &auditToken) { Data($0) }
        return ChromiumBridgePeerIdentity(
            processIdentifier: processIdentifier,
            auditToken: auditTokenData
        )
    }

    static func systemError(operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }

    private static func socketAddress(path: String) throws -> sockaddr_un {
        let pathBytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "Chromium bridge socket path is too long"]
            )
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
            pathBytes.withUnsafeBytes { source in
                memcpy(destination, source.baseAddress!, pathBytes.count)
            }
        }
        return address
    }
}
