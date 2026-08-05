import Foundation

let writeLock = NSLock()

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

func readNativeMessage() -> Data? {
    guard let lengthData = readExact(4) else {
        return nil
    }
    let bytes = [UInt8](lengthData)
    let length = UInt32(bytes[0])
        | UInt32(bytes[1]) << 8
        | UInt32(bytes[2]) << 16
        | UInt32(bytes[3]) << 24
    return readExact(Int(length))
}

func writeNativeMessage(_ payload: Data) {
    var length = UInt32(payload.count).littleEndian
    let lengthData = Data(bytes: &length, count: 4)
    writeLock.lock()
    FileHandle.standardOutput.write(lengthData)
    FileHandle.standardOutput.write(payload)
    writeLock.unlock()
}
