import Foundation
import Network
import DATSignaling

@MainActor
@Observable
final class SignalingChannel {
    enum State: Equatable {
        case idle
        case connecting
        case open
        case closed(reason: String)
    }

    private(set) var state: State = .idle
    private(set) var inbox: [SignalMessage] = []

    private var connection: NWConnection?
    private var rxBuffer = Data()

    /// Adopt an inbound connection (Mac side, called from NWListener).
    /// Rejects the new connection if a channel is already active — single-peer policy.
    func adopt(_ c: NWConnection) -> Bool {
        if connection != nil {
            c.cancel()
            return false
        }
        attach(c)
        return true
    }

    /// Dial an outbound connection (iPhone side).
    func connect(to endpoint: NWEndpoint) {
        teardown(reason: "replaced")
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        params.prohibitedInterfaceTypes = [.cellular]
        attach(NWConnection(to: endpoint, using: params))
    }

    func send(_ message: SignalMessage) {
        guard let c = connection else { return }
        do {
            let data = try LengthPrefixedCodec.encode(message)
            c.send(content: data, completion: .contentProcessed { err in
                if let err = err {
                    Task { @MainActor in self.teardown(reason: "send: \(err.localizedDescription)") }
                }
            })
        } catch {
            teardown(reason: "encode: \(error.localizedDescription)")
        }
    }

    func close(reason: String) { teardown(reason: reason) }

    // MARK: - Internals

    private func attach(_ c: NWConnection) {
        connection = c
        rxBuffer.removeAll()
        state = .connecting
        c.stateUpdateHandler = { [weak self, weak c] s in
            Task { @MainActor in
                guard let self, let c, c === self.connection else { return }
                self.handleState(s)
            }
        }
        c.start(queue: .main)
        receiveLoop(c)
    }

    private func teardown(reason: String) {
        guard let c = connection else { return }
        connection = nil
        c.stateUpdateHandler = nil
        c.cancel()
        rxBuffer.removeAll()
        state = .closed(reason: reason)
    }

    private func handleState(_ s: NWConnection.State) {
        switch s {
        case .ready: state = .open
        case .failed(let e): teardown(reason: e.localizedDescription)
        case .cancelled:
            if connection == nil, case .closed = state {} else {
                state = .closed(reason: "cancelled")
            }
        default: break
        }
    }

    private func receiveLoop(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, err in
            Task { @MainActor in
                guard let self, c === self.connection else { return }
                if let data = data, !data.isEmpty {
                    self.rxBuffer.append(data)
                    do {
                        let messages = try LengthPrefixedCodec.drain(buffer: &self.rxBuffer)
                        self.inbox.append(contentsOf: messages)
                    } catch {
                        self.teardown(reason: "decode: \(error.localizedDescription)")
                        return
                    }
                }
                if let err = err { self.teardown(reason: err.localizedDescription); return }
                if isComplete { self.teardown(reason: "remote closed"); return }
                self.receiveLoop(c)
            }
        }
    }
}
