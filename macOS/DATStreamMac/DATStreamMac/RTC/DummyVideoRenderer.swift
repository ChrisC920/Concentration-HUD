import Foundation
import WebRTC
import DATSignaling

/// Step-6 stand-in renderer. Plain NSObject so libwebrtc's renderer dispatch
/// can find -renderFrame: through the ObjC runtime without @Observable macro
/// interference. State is exposed via thread-safe getters; the UI polls them.
final class DummyVideoRenderer: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var _frameCount: Int = 0
    private var _lastWidth: Int = 0
    private var _lastHeight: Int = 0
    private var _lastTimestampNs: Int64 = 0
    /// iosClock - macClock; macNow + offset ≈ iosClock at the same instant.
    private var _clockOffsetNs: Int64 = 0
    /// Sliding-window of latency samples (last 1s worth at 24fps).
    private var _latencySamples: [Int64] = []
    private var _lastReportTs: Int64 = 0
    private var _latencyP50Ns: Int64 = 0
    private var _latencyP99Ns: Int64 = 0

    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return _frameCount }
    var lastSize: CGSize {
        lock.lock(); defer { lock.unlock() }
        return CGSize(width: _lastWidth, height: _lastHeight)
    }
    var lastTimestampNs: Int64 { lock.lock(); defer { lock.unlock() }; return _lastTimestampNs }
    var latencyP50Ns: Int64 { lock.lock(); defer { lock.unlock() }; return _latencyP50Ns }
    var latencyP99Ns: Int64 { lock.lock(); defer { lock.unlock() }; return _latencyP99Ns }
    var clockOffsetNs: Int64 { lock.lock(); defer { lock.unlock() }; return _clockOffsetNs }

    func setClockOffset(_ offsetNs: Int64) {
        lock.lock()
        _clockOffsetNs = offsetNs
        lock.unlock()
        print("[Latency] clock offset set: \(offsetNs)ns")
    }

    func setSize(_ size: CGSize) {
        lock.lock()
        _lastWidth = Int(size.width)
        _lastHeight = Int(size.height)
        lock.unlock()
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let f = frame else { return }
        let macNow = MachClock.nowNs()
        lock.lock()
        _frameCount &+= 1
        _lastWidth = Int(f.width)
        _lastHeight = Int(f.height)
        _lastTimestampNs = f.timeStampNs
        let n = _frameCount

        // NOTE: per-frame latency via RTCVideoFrame.timeStampNs is unreliable —
        // libwebrtc rewrites the receive-side timestamp using its own clock, so
        // (macNow - frameTs) measures only the renderer dispatch delay, not the
        // glasses → OpenCV path. End-to-end latency will be measured at step 14
        // by encoding a sender-side timecode into the frame pixels (a side
        // channel that survives the encode/decode round-trip) and decoding it
        // on Mac. Clock-offset infrastructure is left in place for that step.
        _ = macNow
        lock.unlock()
        if n % 24 == 1 {
            print("[Renderer] renderFrame #\(n) \(f.width)x\(f.height)")
        }
    }
}
