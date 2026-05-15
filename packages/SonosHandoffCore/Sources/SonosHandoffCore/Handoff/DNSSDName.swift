import Foundation

public enum DNSSDName {
    public static func unescaped(_ value: String) -> String {
        var bytes: [UInt8] = []
        var index = value.startIndex

        while index < value.endIndex {
            guard value[index] == "\\" else {
                bytes.append(contentsOf: String(value[index]).utf8)
                index = value.index(after: index)
                continue
            }

            let escapedStart = value.index(after: index)
            guard escapedStart < value.endIndex else {
                bytes.append(contentsOf: "\\".utf8)
                index = escapedStart
                continue
            }

            var digits = ""
            var digitIndex = escapedStart
            for _ in 0 ..< 3 {
                guard digitIndex < value.endIndex, value[digitIndex].isNumber else {
                    break
                }
                digits.append(value[digitIndex])
                digitIndex = value.index(after: digitIndex)
            }

            if digits.count == 3,
               let scalarValue = UInt32(digits),
               scalarValue <= UInt8.max {
                bytes.append(UInt8(scalarValue))
                index = digitIndex
            } else {
                bytes.append(contentsOf: String(value[escapedStart]).utf8)
                index = value.index(after: escapedStart)
            }
        }

        return String(decoding: bytes, as: UTF8.self)
    }
}
