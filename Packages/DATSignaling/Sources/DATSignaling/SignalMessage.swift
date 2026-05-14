import Foundation

public enum SignalMessage: Codable, Equatable {
    case offer(sdp: String)
    case answer(sdp: String)
    case ice(candidate: String, sdpMid: String?, sdpMLineIndex: Int32)
    case clockProbe(t1Ns: Int64)
    case clockProbeReply(t1Ns: Int64, t2Ns: Int64)
    /// Offset from the responder's clock to the initiator's clock (initiatorNs - responderNs).
    /// The receiver adds this to its own mach time to compare against frame timeStampNs.
    case clockOffset(offsetNs: Int64)
    case bye

    private enum CodingKeys: String, CodingKey {
        case type, sdp, candidate, sdpMid, sdpMLineIndex, t1Ns, t2Ns, offsetNs
    }

    private enum Kind: String, Codable {
        case offer, answer, ice, clockProbe, clockProbeReply, clockOffset, bye
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .offer(let sdp):
            try c.encode(Kind.offer, forKey: .type)
            try c.encode(sdp, forKey: .sdp)
        case .answer(let sdp):
            try c.encode(Kind.answer, forKey: .type)
            try c.encode(sdp, forKey: .sdp)
        case .ice(let candidate, let mid, let idx):
            try c.encode(Kind.ice, forKey: .type)
            try c.encode(candidate, forKey: .candidate)
            try c.encodeIfPresent(mid, forKey: .sdpMid)
            try c.encode(idx, forKey: .sdpMLineIndex)
        case .clockProbe(let t1):
            try c.encode(Kind.clockProbe, forKey: .type)
            try c.encode(t1, forKey: .t1Ns)
        case .clockProbeReply(let t1, let t2):
            try c.encode(Kind.clockProbeReply, forKey: .type)
            try c.encode(t1, forKey: .t1Ns)
            try c.encode(t2, forKey: .t2Ns)
        case .clockOffset(let off):
            try c.encode(Kind.clockOffset, forKey: .type)
            try c.encode(off, forKey: .offsetNs)
        case .bye:
            try c.encode(Kind.bye, forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .offer:
            self = .offer(sdp: try c.decode(String.self, forKey: .sdp))
        case .answer:
            self = .answer(sdp: try c.decode(String.self, forKey: .sdp))
        case .ice:
            self = .ice(
                candidate: try c.decode(String.self, forKey: .candidate),
                sdpMid: try c.decodeIfPresent(String.self, forKey: .sdpMid),
                sdpMLineIndex: try c.decode(Int32.self, forKey: .sdpMLineIndex)
            )
        case .clockProbe:
            self = .clockProbe(t1Ns: try c.decode(Int64.self, forKey: .t1Ns))
        case .clockProbeReply:
            self = .clockProbeReply(
                t1Ns: try c.decode(Int64.self, forKey: .t1Ns),
                t2Ns: try c.decode(Int64.self, forKey: .t2Ns)
            )
        case .clockOffset:
            self = .clockOffset(offsetNs: try c.decode(Int64.self, forKey: .offsetNs))
        case .bye:
            self = .bye
        }
    }
}
