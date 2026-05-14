import Foundation
import WebRTC

/// Process-wide RTCPeerConnectionFactory. WebRTC strongly recommends a single
/// factory per process; recreating it leaks worker threads and SSL state.
enum RTCFactoryHost {
    static let shared: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()
}
