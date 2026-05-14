import Foundation

public enum LengthPrefixedCodecError: Error {
    case messageTooLarge(Int)
    case truncated
}

public enum LengthPrefixedCodec {
    public static let maxMessageBytes: Int = 4 * 1024 * 1024  // 4 MiB safety cap

    /// Encodes a `SignalMessage` as JSON prefixed with a 4-byte big-endian length.
    public static func encode(_ message: SignalMessage) throws -> Data {
        let json = try JSONEncoder().encode(message)
        guard json.count <= maxMessageBytes else {
            throw LengthPrefixedCodecError.messageTooLarge(json.count)
        }
        var out = Data(capacity: 4 + json.count)
        var be = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        out.append(json)
        return out
    }

    /// Drains zero or more complete frames from `buffer`, decoding each into a `SignalMessage`.
    /// Consumed bytes are removed from `buffer`. A trailing partial frame is left in place.
    public static func drain(buffer: inout Data) throws -> [SignalMessage] {
        var messages: [SignalMessage] = []
        while buffer.count >= 4 {
            let length = buffer.withUnsafeBytes { raw -> UInt32 in
                let p = raw.baseAddress!.assumingMemoryBound(to: UInt32.self)
                return UInt32(bigEndian: p.pointee)
            }
            let total = 4 + Int(length)
            guard Int(length) <= maxMessageBytes else {
                throw LengthPrefixedCodecError.messageTooLarge(Int(length))
            }
            guard buffer.count >= total else { break }
            let payload = buffer.subdata(in: 4..<total)
            let message = try JSONDecoder().decode(SignalMessage.self, from: payload)
            messages.append(message)
            buffer.removeSubrange(0..<total)
        }
        return messages
    }
}
