import Foundation
import Network
import DATSignaling

@MainActor
@Observable
final class BonjourAdvertiser {
    enum State: Equatable {
        case idle
        case advertising(port: UInt16)
        case failed(String)
    }

    private(set) var state: State = .idle

    /// Single active channel — Mac accepts at most one peer at a time (prototype scope).
    let channel = SignalingChannel()

    private var listener: NWListener?

    func start() {
        stop()
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(
                name: BonjourConfig.serviceName,
                type: BonjourConfig.serviceType,
                txtRecord: makeTXTRecord()
            )
            listener.stateUpdateHandler = { [weak self] s in
                Task { @MainActor in self?.handleListenerState(s) }
            }
            listener.newConnectionHandler = { [weak self] c in
                Task { @MainActor in
                    guard let self else { c.cancel(); return }
                    if !self.channel.adopt(c) {
                        // Already have an active peer; reject this one cleanly.
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            state = .failed("listener init: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        channel.close(reason: "advertiser stopped")
        state = .idle
    }

    private func handleListenerState(_ s: NWListener.State) {
        switch s {
        case .ready:
            let port = listener?.port?.rawValue ?? 0
            state = .advertising(port: port)
        case .failed(let err):
            state = .failed(err.localizedDescription)
        case .cancelled:
            if state != .idle { state = .idle }
        default: break
        }
    }

    private func makeTXTRecord() -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt[BonjourConfig.txtVersionKey] = String(BonjourConfig.protocolVersion)
        return txt
    }
}
