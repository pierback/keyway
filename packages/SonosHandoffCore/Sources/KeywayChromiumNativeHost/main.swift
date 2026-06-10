import Foundation

let snapshotNotificationName = Notification.Name("com.fpieringer.keyway.chromium.snapshot")
let commandResultNotificationName = Notification.Name("com.fpieringer.keyway.chromium.commandResult")
let commandNotificationName = Notification.Name("com.fpieringer.keyway.chromium.command")
let hostName = "com.fpieringer.keyway.chromium"
let writeLock = NSLock()

struct NativeMessageEnvelope: Decodable {
    let type: String
}

func readExact(_ byteCount: Int) -> Data? {
    var data = Data()
    while data.count < byteCount {
        let chunk = FileHandle.standardInput.readData(ofLength: byteCount - data.count)
        if chunk.isEmpty {
            return nil
        }
        data.append(chunk)
    }
    return data
}

func readNativeMessage() -> String? {
    guard let lengthData = readExact(4) else {
        return nil
    }
    let bytes = [UInt8](lengthData)
    let length = UInt32(bytes[0])
        | UInt32(bytes[1]) << 8
        | UInt32(bytes[2]) << 16
        | UInt32(bytes[3]) << 24
    guard let payload = readExact(Int(length)) else {
        return nil
    }
    return String(data: payload, encoding: .utf8)
}

func writeNativeMessage(_ payload: String) {
    let data = Data(payload.utf8)
    var length = UInt32(data.count).littleEndian
    let lengthData = Data(bytes: &length, count: 4)
    writeLock.lock()
    FileHandle.standardOutput.write(lengthData)
    FileHandle.standardOutput.write(data)
    writeLock.unlock()
}

let commandObserver = DistributedNotificationCenter.default().addObserver(
    forName: commandNotificationName,
    object: hostName,
    queue: .main
) { notification in
    guard let payload = notification.userInfo?["payload"] as? String else {
        preconditionFailure("Keyway command notifications must include a payload.")
    }
    writeNativeMessage(payload)
}

func postNativeMessage(_ payload: String) {
    let data = Data(payload.utf8)
    let envelope = try! JSONDecoder().decode(NativeMessageEnvelope.self, from: data)
    precondition(
        envelope.type == "snapshot" || envelope.type == "hello" || envelope.type == "commandResult",
        "Unknown Chromium native message type: \(envelope.type)"
    )
    guard envelope.type == "snapshot" || envelope.type == "commandResult" else {
        return
    }
    DistributedNotificationCenter.default().postNotificationName(
        envelope.type == "snapshot" ? snapshotNotificationName : commandResultNotificationName,
        object: hostName,
        userInfo: ["payload": payload],
        deliverImmediately: true
    )
}

DispatchQueue.global(qos: .userInitiated).async {
    while let payload = readNativeMessage() {
        postNativeMessage(payload)
    }
    exit(0)
}

RunLoop.main.run()
DistributedNotificationCenter.default().removeObserver(commandObserver)
