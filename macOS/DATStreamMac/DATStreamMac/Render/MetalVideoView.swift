import SwiftUI
import WebRTC

/// SwiftUI wrapper around RTCMTLNSVideoView. Used as a known-good reference
/// renderer to confirm whether the inbound track is actually delivering frames.
struct MetalVideoView: NSViewRepresentable {
    let track: RTCVideoTrack?

    func makeNSView(context: Context) -> RTCMTLNSVideoView {
        let v = RTCMTLNSVideoView(frame: .zero)
        if let track {
            track.add(v)
        }
        return v
    }

    func updateNSView(_ nsView: RTCMTLNSVideoView, context: Context) {
        if let track {
            track.add(nsView)
        }
    }
}
