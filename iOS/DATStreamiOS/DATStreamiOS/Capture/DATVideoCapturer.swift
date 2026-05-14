import Foundation
import WebRTC
import CoreMedia
import MWDATCamera
import DATSignaling

/// Bridges DAT SDK frames into WebRTC. Receives `MWDATCamera.VideoFrame`s
/// from the publisher callback and forwards their `CVPixelBuffer` (extracted
/// zero-copy from the wrapped `CMSampleBuffer`) into the libwebrtc encoder.
///
/// The DAT publisher invokes the closure on its own thread; this class does
/// not retain the `CMSampleBuffer` past the closure scope. `RTCCVPixelBuffer`
/// retains the underlying `CVPixelBuffer`, which is sufficient.
final class DATVideoCapturer: RTCVideoCapturer, @unchecked Sendable {
    /// Atomic counter readable from any thread — surfaces capture activity in the UI.
    private let counterLock = NSLock()
    private var _frameCount: Int = 0
    var frameCount: Int { counterLock.lock(); defer { counterLock.unlock() }; return _frameCount }

    /// Forwards a DAT video frame into the WebRTC source. Cheap; safe to call
    /// from DAT's publisher callback thread synchronously.
    func ingest(_ frame: VideoFrame) {
        guard let pb = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else {
            print("[DATCapturer] ingest: CMSampleBufferGetImageBuffer returned nil")
            return
        }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let buf = RTCCVPixelBuffer(pixelBuffer: pb)
        let rtcFrame = RTCVideoFrame(buffer: buf, rotation: ._0, timeStampNs: MachClock.nowNs())
        delegate?.capturer(self, didCapture: rtcFrame)

        counterLock.lock()
        _frameCount &+= 1
        let n = _frameCount
        counterLock.unlock()

        if n == 1 || n % 24 == 0 {
            print("[DATCapturer] ingest #\(n) \(w)x\(h) delegate=\(delegate == nil ? "nil" : "set")")
        }
    }
}
