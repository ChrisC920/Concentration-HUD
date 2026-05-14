import Foundation
import WebRTC
import DATSignaling

/// Mac-side recvOnly peer connection. Driven by the SignalingChannel: consumes
/// `offer` / `ice` from the remote, produces `answer` / `ice` outbound.
@MainActor
@Observable
final class RTCConnection: NSObject {
    enum State: Equatable {
        case idle
        case haveRemoteOffer
        case answering
        case connected
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var iceState: String = "new"
    private(set) var trackCount: Int = 0

    nonisolated let renderer = DummyVideoRenderer()
    /// Reference to the live track so the UI can attach an RTCMTLVideoView.
    private(set) var liveTrack: RTCVideoTrack?

    private var peer: RTCPeerConnection?
    private weak var channel: SignalingChannel?
    private var signalingObserver: Task<Void, Never>?
    private var consumedInboxCount = 0
    private var attachedTrackIds: Set<String> = []
    private var extraRenderers: [RTCVideoRenderer] = []

    /// Additive: attach any extra RTCVideoRenderer (e.g. GazeAnalyzer) to the
    /// current and future live tracks, without disturbing the existing renderer
    /// or signaling pipeline.
    func attachExtraRenderer(_ renderer: RTCVideoRenderer) {
        extraRenderers.append(renderer)
        if let track = liveTrack {
            track.add(renderer)
        }
    }

    func bind(channel: SignalingChannel) {
        self.channel = channel
        signalingObserver?.cancel()
        // Poll the channel's inbox via Observation: re-evaluates whenever
        // `inbox` mutates because it's accessed inside withObservationTracking.
        signalingObserver = Task { @MainActor [weak self] in
            await self?.observeInbox()
        }
    }

    private func observeInbox() async {
        while !Task.isCancelled {
            let snapshot: [SignalMessage] = withObservationTracking {
                channel?.inbox ?? []
            } onChange: {
                // Re-fire by yielding; the next loop iteration captures the new value.
            }
            if snapshot.count > consumedInboxCount {
                let new = Array(snapshot[consumedInboxCount..<snapshot.count])
                consumedInboxCount = snapshot.count
                for msg in new { await handle(msg) }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        }
    }

    private func handle(_ msg: SignalMessage) async {
        switch msg {
        case .offer(let sdp):
            await acceptOffer(sdp: sdp)
        case .ice(let cand, let mid, let idx):
            await addRemoteCandidate(cand, mid: mid, idx: idx)
        case .clockProbe(let t1):
            // Stamp t2 on this side immediately and echo back with t1.
            channel?.send(.clockProbeReply(t1Ns: t1, t2Ns: MachClock.nowNs()))
        case .clockOffset(let off):
            renderer.setClockOffset(off)
        case .bye:
            teardown(reason: "remote bye")
        default:
            break
        }
    }

    func teardown(reason: String) {
        peer?.close()
        peer = nil
        signalingObserver?.cancel()
        signalingObserver = nil
        consumedInboxCount = 0
        attachedTrackIds.removeAll()
        state = state == .idle ? .idle : .failed(reason)
        iceState = "closed"
        trackCount = 0
    }

    // MARK: - SDP

    private func ensurePeer() {
        guard peer == nil else { return }
        let cfg = RTCConfiguration()
        cfg.iceServers = []
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require
        cfg.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peer = RTCFactoryHost.shared.peerConnection(with: cfg, constraints: constraints, delegate: self)
        // No pre-created transceiver: under Unified Plan, the offer's m-line creates
        // the recvOnly transceiver implicitly during setRemoteDescription. Pre-creating
        // one causes duplicate transceivers and inflated track counts.
    }

    private func acceptOffer(sdp: String) async {
        ensurePeer()
        guard let peer else { return }
        state = .haveRemoteOffer
        let remote = RTCSessionDescription(type: .offer, sdp: sdp)
        do {
            try await peer.setRemoteDescription(remote)
        } catch {
            state = .failed("setRemote: \(error.localizedDescription)")
            return
        }

        attachRenderersFromTransceivers(tag: "post-setRemote")

        state = .answering
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answer: RTCSessionDescription
        do {
            answer = try await peer.answer(for: constraints)
            try await peer.setLocalDescription(answer)
        } catch {
            state = .failed("answer/setLocal: \(error.localizedDescription)")
            return
        }
        attachRenderersFromTransceivers(tag: "post-setLocal")
        channel?.send(.answer(sdp: answer.sdp))
        startStatsPolling()
    }

    private var statsTask: Task<Void, Never>?
    private func startStatsPolling() {
        statsTask?.cancel()
        statsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, let peer = self.peer else { return }
                peer.statistics { report in
                    var inboundVideo: [String: Any] = [:]
                    for (_, s) in report.statistics where s.type == "inbound-rtp" {
                        if (s.values["kind"] as? String) == "video" {
                            inboundVideo["packetsReceived"] = s.values["packetsReceived"]
                            inboundVideo["bytesReceived"] = s.values["bytesReceived"]
                            inboundVideo["framesReceived"] = s.values["framesReceived"]
                            inboundVideo["framesDecoded"] = s.values["framesDecoded"]
                            inboundVideo["framesDropped"] = s.values["framesDropped"]
                            inboundVideo["decoderImplementation"] = s.values["decoderImplementation"]
                            inboundVideo["frameWidth"] = s.values["frameWidth"]
                            inboundVideo["frameHeight"] = s.values["frameHeight"]
                        }
                    }
                    print("[RTC mac stats] inbound-video=\(inboundVideo)")
                }
            }
        }
    }

    private func attachRenderersFromTransceivers(tag: String) {
        guard let peer else { return }
        let videoTransceivers = peer.transceivers.filter { $0.mediaType == .video }
        print("[RTC mac attach \(tag)] video transceivers: \(videoTransceivers.count)")
        for (i, t) in videoTransceivers.enumerated() {
            let track = t.receiver.track
            print("[RTC mac attach \(tag)]   t[\(i)] dir=\(t.direction.rawValue) mid=\(t.mid) receiverTrack=\(String(describing: track?.trackId)) kind=\(String(describing: track?.kind)) isVideo=\(track is RTCVideoTrack)")
            guard let vtrack = track as? RTCVideoTrack else { continue }
            guard !attachedTrackIds.contains(vtrack.trackId) else {
                print("[RTC mac attach \(tag)]   already attached \(vtrack.trackId)")
                continue
            }
            attachedTrackIds.insert(vtrack.trackId)
            vtrack.isEnabled = true
            vtrack.add(renderer)
            for extra in extraRenderers { vtrack.add(extra) }
            liveTrack = vtrack
            trackCount = attachedTrackIds.count
            print("[RTC mac attach \(tag)]   ATTACHED renderer to \(vtrack.trackId) isEnabled=\(vtrack.isEnabled)")
        }
    }

    private func addRemoteCandidate(_ cand: String, mid: String?, idx: Int32) async {
        guard let peer else { return }
        let candidate = RTCIceCandidate(sdp: cand, sdpMLineIndex: idx, sdpMid: mid)
        do {
            try await peer.add(candidate)
        } catch {
            // Non-fatal; some candidates fail when ICE has already succeeded.
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension RTCConnection: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCSignalingState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let label: String = {
            switch newState {
            case .new: return "new"
            case .checking: return "checking"
            case .connected: return "connected"
            case .completed: return "completed"
            case .failed: return "failed"
            case .disconnected: return "disconnected"
            case .closed: return "closed"
            case .count: return "count"
            @unknown default: return "unknown"
            }
        }()
        Task { @MainActor in
            self.iceState = label
            if newState == .connected || newState == .completed {
                self.state = .connected
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let cand = candidate.sdp
        let mid = candidate.sdpMid
        let idx = candidate.sdpMLineIndex
        Task { @MainActor in
            self.channel?.send(.ice(candidate: cand, sdpMid: mid, sdpMLineIndex: idx))
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        let track = rtpReceiver.track
        print("[RTC mac didAdd] receiver fired track=\(String(describing: track?.trackId)) kind=\(String(describing: track?.kind))")
        guard let vtrack = track as? RTCVideoTrack else { return }
        let renderer = self.renderer
        vtrack.add(renderer)
        print("[RTC mac didAdd] ATTACHED renderer to \(vtrack.trackId)")
        Task { @MainActor in
            self.attachedTrackIds.insert(vtrack.trackId)
            self.trackCount = self.attachedTrackIds.count
            for extra in self.extraRenderers { vtrack.add(extra) }
        }
    }
}
