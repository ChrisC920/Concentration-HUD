import Foundation
import WebRTC
import DATSignaling

/// iPhone-side sendOnly peer connection. Owns the video source/track wired to
/// the DAT video capturer that is injected by `DATSessionController`. The
/// capturer's frame lifecycle is controlled by the DAT StreamSession; this
/// class only handles the WebRTC plumbing.
@MainActor
@Observable
final class RTCConnection: NSObject {
    enum State: Equatable {
        case idle
        case offering
        case haveLocalOffer
        case connected
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var iceState: String = "new"
    private(set) var clockOffsetNs: Int64 = 0
    private(set) var clockProbeRtts: [Int64] = []

    private var peer: RTCPeerConnection?
    private weak var channel: SignalingChannel?
    private var signalingObserver: Task<Void, Never>?
    private var consumedInboxCount = 0
    private var pendingProbes: [Int64: Int64] = [:]  // t1Ns -> sentMachNs (same value; for outstanding tracking)
    private var probeSamples: [(rttNs: Int64, offsetNs: Int64)] = []

    private var videoSource: RTCVideoSource?
    private var videoTrack: RTCVideoTrack?
    /// External capturer injected by DATSessionController. RTCConnection
    /// only references this to wire it to the RTCVideoSource as delegate; it
    /// does NOT control start/stop (DAT does that).
    private(set) var capturer: DATVideoCapturer?

    func bind(channel: SignalingChannel) {
        self.channel = channel
        signalingObserver?.cancel()
        signalingObserver = Task { @MainActor [weak self] in
            await self?.observeInbox()
        }
    }

    private func observeInbox() async {
        while !Task.isCancelled {
            let snapshot: [SignalMessage] = withObservationTracking {
                channel?.inbox ?? []
            } onChange: { }
            if snapshot.count > consumedInboxCount {
                let new = Array(snapshot[consumedInboxCount..<snapshot.count])
                consumedInboxCount = snapshot.count
                for msg in new { await handle(msg) }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func handle(_ msg: SignalMessage) async {
        switch msg {
        case .answer(let sdp):
            await acceptAnswer(sdp: sdp)
        case .ice(let cand, let mid, let idx):
            await addRemoteCandidate(cand, mid: mid, idx: idx)
        case .clockProbeReply(let t1, let t2):
            handleClockProbeReply(t1: t1, t2: t2)
        case .bye:
            teardown(reason: "remote bye")
        default:
            break
        }
    }

    /// Sends N clock probes back-to-back, then computes the offset from the
    /// best (lowest-RTT) samples and pushes it to the Mac. NTP-style:
    ///   offset ≈ ((t2 - t1) + (t2 - t4)) / 2  (treating t3 ≈ t2 since the
    ///   responder stamps t2 once and reuses it as the send time)
    func runClockProbes(count: Int = 4) async {
        probeSamples.removeAll()
        for _ in 0..<count {
            let t1 = MachClock.nowNs()
            channel?.send(.clockProbe(t1Ns: t1))
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // Allow up to 500ms for replies.
        try? await Task.sleep(nanoseconds: 500_000_000)
        finalizeClockProbes()
    }

    private func handleClockProbeReply(t1: Int64, t2: Int64) {
        let t4 = MachClock.nowNs()
        let rtt = t4 - t1
        // offsetNs is iOS-clock minus Mac-clock, applied to Mac frame timestamps.
        // Sender stamps frames in iOS-clock; Mac samples macNow on render. To compare:
        //   latency_ns = macNow + offset - frameTsIos       <-- positive means latency
        // Simpler: send (iosClock - macClock) so Mac computes
        //   latency = (macNow + offsetNs) - frameTimeStampNs
        // Using midpoint estimator: offset = ((t2 - t1) + (t2 - t4)) / 2
        let offset = ((t2 - t1) + (t2 - t4)) / 2
        // We want iosClock - macClock so Mac can do macNow + offset → iosClock.
        // The midpoint formula above gives macClock - iosClock, so flip sign.
        let iosMinusMac = -offset
        probeSamples.append((rttNs: rtt, offsetNs: iosMinusMac))
    }

    private func finalizeClockProbes() {
        guard !probeSamples.isEmpty else {
            print("[Clock] no probe samples received")
            return
        }
        // Use the sample with the lowest RTT — least skewed by network jitter.
        let best = probeSamples.min(by: { $0.rttNs < $1.rttNs })!
        clockOffsetNs = best.offsetNs
        clockProbeRtts = probeSamples.map { $0.rttNs }
        let rttsMs = clockProbeRtts.map { Double($0) / 1_000_000.0 }
        print("[Clock] samples=\(probeSamples.count) rtts(ms)=\(rttsMs.map { String(format: "%.2f", $0) }) bestRTT=\(Double(best.rttNs)/1e6)ms offsetNs=\(clockOffsetNs)")
        channel?.send(.clockOffset(offsetNs: clockOffsetNs))
    }

    /// Inject the DAT capturer. Must be called before startOffer so the
    /// RTCVideoSource is wired up at the time the offer is negotiated.
    func attach(capturer: DATVideoCapturer) {
        self.capturer = capturer
    }

    func startOffer() async {
        ensurePeer()
        guard let peer else { return }
        // Estimate clock offset before negotiation so the Mac has it well before
        // the first decoded frame lands.
        await runClockProbes()
        state = .offering
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        do {
            let rawOffer = try await peer.offer(for: constraints)
            // Force H.264 Constrained Baseline + 6 Mbps cap. Must re-parse before setLocal.
            let mungedSdp = SDPMunger.forceH264AndBitrate(rawOffer.sdp, bitrateKbps: 12000)
            let mungedOffer = RTCSessionDescription(type: .offer, sdp: mungedSdp)
            print("[RTC ios] MUNGED OFFER (m=video + codec lines):")
            for line in mungedSdp.components(separatedBy: "\r\n") where line.hasPrefix("m=video") || line.hasPrefix("a=rtpmap") || line.hasPrefix("b=AS") {
                print("  \(line)")
            }
            try await peer.setLocalDescription(mungedOffer)
            state = .haveLocalOffer
            applySenderEncodingParams()
            channel?.send(.offer(sdp: mungedOffer.sdp))
            startStatsPolling()
        } catch {
            state = .failed("offer: \(error.localizedDescription)")
        }
    }

    private func applySenderEncodingParams() {
        guard let peer else { return }
        for sender in peer.senders where sender.track?.kind == "video" {
            let params = sender.parameters
            // Resolution-preserving on a LAN: don't trade pixels for bitrate or
            // framerate when libwebrtc thinks the link is "constrained" — it
            // misjudges burst BT-Classic input and otherwise pins us at half-res.
            params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
            for enc in params.encodings {
                enc.maxBitrateBps = NSNumber(value: 12_000_000)
                enc.minBitrateBps = NSNumber(value: 6_000_000)
                enc.maxFramerate = NSNumber(value: 24)
                enc.scaleResolutionDownBy = NSNumber(value: 1.0)
            }
            sender.parameters = params
        }
    }

    private var statsTask: Task<Void, Never>?
    private func startStatsPolling() {
        statsTask?.cancel()
        statsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, let peer = self.peer else { return }
                peer.statistics { report in
                    var outboundVideo: [String: Any] = [:]
                    var mediaSource: [String: Any] = [:]
                    for (_, s) in report.statistics {
                        if s.type == "outbound-rtp", (s.values["kind"] as? String) == "video" {
                            outboundVideo["packetsSent"] = s.values["packetsSent"]
                            outboundVideo["bytesSent"] = s.values["bytesSent"]
                            outboundVideo["framesSent"] = s.values["framesSent"]
                            outboundVideo["framesEncoded"] = s.values["framesEncoded"]
                            outboundVideo["encoderImplementation"] = s.values["encoderImplementation"]
                            outboundVideo["frameWidth"] = s.values["frameWidth"]
                            outboundVideo["frameHeight"] = s.values["frameHeight"]
                        }
                        if s.type == "media-source" {
                            mediaSource["framesPerSecond"] = s.values["framesPerSecond"]
                            mediaSource["frames"] = s.values["frames"]
                            mediaSource["width"] = s.values["width"]
                            mediaSource["height"] = s.values["height"]
                        }
                    }
                    print("[RTC ios stats] media-source=\(mediaSource) outbound=\(outboundVideo)")
                }
            }
        }
    }

    func teardown(reason: String) {
        peer?.close()
        peer = nil
        videoSource = nil
        videoTrack = nil
        signalingObserver?.cancel()
        signalingObserver = nil
        consumedInboxCount = 0
        state = state == .idle ? .idle : .failed(reason)
        iceState = "closed"
    }

    private func ensurePeer() {
        guard peer == nil else { return }
        let cfg = RTCConfiguration()
        cfg.iceServers = []
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require
        cfg.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = RTCFactoryHost.shared.peerConnection(with: cfg, constraints: constraints, delegate: self) else {
            state = .failed("peerConnection() returned nil")
            return
        }
        self.peer = pc

        // Build video source + track. The capturer is owned externally
        // (by DATSessionController) and injected via attach(capturer:).
        let source = RTCFactoryHost.shared.videoSource()
        // CRITICAL: must declare the output format. Without this, RTCVideoSource
        // silently drops frames from custom capturers because it doesn't know
        // what to forward to the encoder.
        // adaptOutputFormat sets a *target aspect ratio + pixel ceiling*, not a
        // per-axis cap — declaring a ratio that doesn't match the source crops.
        // Match the glasses' 3:4 portrait output (480x640 today). If the
        // glasses ever emit a different aspect, this needs to track it.
        source.adaptOutputFormat(toWidth: 1440, height: 1920, fps: 30)
        self.videoSource = source
        self.capturer?.delegate = source

        let track = RTCFactoryHost.shared.videoTrack(with: source, trackId: "datstream-video")
        self.videoTrack = track

        let init_ = RTCRtpTransceiverInit()
        init_.direction = .sendOnly
        _ = pc.addTransceiver(with: track, init: init_)
    }

    private func acceptAnswer(sdp: String) async {
        guard let peer else { return }
        let remote = RTCSessionDescription(type: .answer, sdp: sdp)
        do {
            try await peer.setRemoteDescription(remote)
        } catch {
            state = .failed("setRemote(answer): \(error.localizedDescription)")
        }
    }

    private func addRemoteCandidate(_ cand: String, mid: String?, idx: Int32) async {
        guard let peer else { return }
        let candidate = RTCIceCandidate(sdp: cand, sdpMLineIndex: idx, sdpMid: mid)
        do {
            try await peer.add(candidate)
        } catch {
            // Tolerate late candidates.
        }
    }
}

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
}
