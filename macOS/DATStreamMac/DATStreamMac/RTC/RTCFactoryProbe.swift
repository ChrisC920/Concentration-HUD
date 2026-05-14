import Foundation
import WebRTC

@MainActor
@Observable
final class RTCFactoryProbe {
    private(set) var summary: String = "not run"
    private(set) var ok: Bool = false

    func run() {
        _ = RTCFactoryHost.shared
        let decoderCodecs = RTCDefaultVideoDecoderFactory().supportedCodecs().map { $0.name }
        let unique = Array(Set(decoderCodecs)).sorted()
        ok = !unique.isEmpty
        summary = "factory ok • decoder codecs: \(unique.joined(separator: ", "))"
    }
}
