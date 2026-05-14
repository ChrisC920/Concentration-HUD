import XCTest
@testable import DATSignaling

final class LengthPrefixedCodecTests: XCTestCase {
    func testRoundTripAllMessageKinds() throws {
        let messages: [SignalMessage] = [
            .offer(sdp: "v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\n"),
            .answer(sdp: "v=0\r\nanswer\r\n"),
            .ice(candidate: "candidate:842163049 1 udp 1677729535", sdpMid: "0", sdpMLineIndex: 0),
            .ice(candidate: "x", sdpMid: nil, sdpMLineIndex: 1),
            .clockProbe(t1Ns: 1_234_567_890),
            .clockProbeReply(t1Ns: 1_234_567_890, t2Ns: 2_345_678_901),
            .bye,
        ]

        var stream = Data()
        for m in messages { stream.append(try LengthPrefixedCodec.encode(m)) }

        var buffer = stream
        let decoded = try LengthPrefixedCodec.drain(buffer: &buffer)
        XCTAssertEqual(decoded, messages)
        XCTAssertEqual(buffer.count, 0)
    }

    func testPartialFrameLeftInBuffer() throws {
        let m = SignalMessage.offer(sdp: "hello")
        let frame = try LengthPrefixedCodec.encode(m)

        var buffer = frame.prefix(frame.count - 1)  // truncate last byte
        let decoded = try LengthPrefixedCodec.drain(buffer: &buffer)
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertEqual(buffer.count, frame.count - 1)

        buffer.append(frame.suffix(1))
        let decoded2 = try LengthPrefixedCodec.drain(buffer: &buffer)
        XCTAssertEqual(decoded2, [m])
        XCTAssertEqual(buffer.count, 0)
    }

    func testMultipleFramesInOneBuffer() throws {
        let frames = [
            try LengthPrefixedCodec.encode(.bye),
            try LengthPrefixedCodec.encode(.clockProbe(t1Ns: 1)),
            try LengthPrefixedCodec.encode(.clockProbeReply(t1Ns: 1, t2Ns: 2)),
        ]
        var buffer = frames.reduce(Data(), +)
        let decoded = try LengthPrefixedCodec.drain(buffer: &buffer)
        XCTAssertEqual(decoded, [.bye, .clockProbe(t1Ns: 1), .clockProbeReply(t1Ns: 1, t2Ns: 2)])
    }

    func testProtocolVersionConstant() {
        XCTAssertEqual(BonjourConfig.serviceType, "_dat-stream._tcp")
        XCTAssertGreaterThan(BonjourConfig.protocolVersion, 0)
    }
}
