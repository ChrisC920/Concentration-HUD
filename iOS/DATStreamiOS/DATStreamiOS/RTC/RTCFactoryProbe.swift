import Foundation
import WebRTC

@MainActor
@Observable
final class RTCFactoryProbe {
    private(set) var summary: String = "not run"
    private(set) var ok: Bool = false

    func run() {
        _ = RTCFactoryHost.shared
        let codecs = RTCDefaultVideoEncoderFactory().supportedCodecs().map { $0.name }
        let unique = Array(Set(codecs)).sorted()
        ok = !unique.isEmpty
        summary = "factory ok • encoder codecs: \(unique.joined(separator: ", "))"
    }
}
