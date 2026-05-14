import Foundation
import MWDATCore
import MWDATCamera
import MWDATMockDevice

/// Owns the DAT SDK lifecycle: registration → DeviceSession.start → camera
/// permission → StreamSession capability → frame publisher. Exposes
/// observable state for the UI and a single `capturer` that the WebRTC
/// pipeline plugs into.
///
/// The DAT API on 0.6.x:
///   1. Wearables.shared.startRegistration()  (async throws)
///   2. handleUrl(_:) on the URL callback
///   3. Wearables.shared.createSession(deviceSelector:) -> DeviceSession
///   4. deviceSession.start()
///   5. Wearables.shared.requestPermission(.camera) -> .granted
///   6. let stream = deviceSession.addStream(config:)
///   7. listen on stream.statePublisher and stream.videoFramePublisher
@MainActor
@Observable
final class DATSessionController {
    enum RegState: Equatable {
        case unknown
        case unavailable
        case available
        case registering
        case registered
        case failed(String)
    }

    enum SessionState: Equatable {
        case idle
        case waitingForDevice
        case starting
        case streaming
        case paused
        case stopping
        case stopped
        case unknown(String)
    }

    /// Frame source. `realGlasses` requires successful Meta AI registration
    /// + paired-and-connected Ray-Ban Meta hardware. `mockDevice` uses the
    /// MWDATMockDevice kit to feed the iPhone's back camera through the
    /// same StreamSession publisher pipeline — DAT downstream code is
    /// unchanged, only the upstream device differs.
    enum Source: String, CaseIterable, Equatable, Identifiable {
        case realGlasses
        case mockDevice
        var id: String { rawValue }
        var label: String {
            switch self {
            case .realGlasses: return "Real Ray-Ban Meta"
            case .mockDevice: return "Mock device (iPhone camera)"
            }
        }
    }

    private(set) var regState: RegState = .unknown
    private(set) var sessionState: SessionState = .idle
    private(set) var lastError: String?
    /// Identifiers of currently visible (paired + reachable) Meta devices.
    /// Empty until the SDK enumerates devices (which only happens after
    /// successful registration).
    private(set) var deviceIds: [String] = []
    /// Active source. Mutable until the StreamSession is armed.
    var source: Source = .realGlasses

    let capturer = DATVideoCapturer()

    private var deviceSession: DeviceSession?
    private var streamSession: StreamSession?
    private var stateToken: (any AnyListenerToken)?
    private var frameToken: (any AnyListenerToken)?
    private var regObserver: Task<Void, Never>?
    private var deviceObserver: Task<Void, Never>?
    private var mockDevice: (any MockRaybanMeta)?

    init() {
        observeRegistrationState()
        observeDevices()
    }

    /// Toggle MockDeviceKit on/off based on the user's selected source.
    /// Call BEFORE registration — `enable(config: initiallyRegistered: true)`
    /// short-circuits the entire Meta AI bounce. The mock kit must be
    /// enabled before `Wearables.configure()` reads its state, but in 0.6.x
    /// `enable()` can be called after configure as well — it just affects
    /// subsequent SDK calls.
    func selectSource(_ newSource: Source) {
        guard newSource != source else { return }
        source = newSource
        if newSource == .mockDevice {
            // Enable mock kit with auto-registered + auto-granted permissions
            // so the user doesn't need to navigate the Meta AI flow at all.
            let cfg = MockDeviceKitConfig(
                initiallyRegistered: true,
                initialPermissionsGranted: true
            )
            MockDeviceKit.shared.enable(config: cfg)
            // Force regState to reflect the new (mocked) registration without
            // waiting on the registrationStateStream to deliver — the stream
            // sometimes doesn't re-emit if it already pushed `.unavailable`.
            regState = .registered
            print("[DAT mock] enabled MockDeviceKit (initiallyRegistered=true, initialPermissionsGranted=true)")
        } else {
            MockDeviceKit.shared.disable()
            mockDevice = nil
            print("[DAT mock] disabled MockDeviceKit")
        }
    }

    private func observeDevices() {
        deviceObserver?.cancel()
        deviceObserver = Task { @MainActor [weak self] in
            guard let self else { return }
            for await devices in Wearables.shared.devicesStream() {
                self.deviceIds = devices.map { String(describing: $0) }
                print("[DAT] devices=\(self.deviceIds)")
            }
        }
    }

    // MARK: - Registration

    func startRegistration() {
        Task { @MainActor in
            do {
                regState = .registering
                try await Wearables.shared.startRegistration()
            } catch let regErr as RegistrationError {
                let label: String
                switch regErr {
                case .alreadyRegistered: label = "alreadyRegistered"
                case .configurationInvalid: label = "configurationInvalid (Info.plist MWDAT keys wrong)"
                case .metaAINotInstalled: label = "metaAINotInstalled (install Meta AI app)"
                case .networkUnavailable: label = "networkUnavailable"
                case .unknown: label = "unknown"
                @unknown default: label = "@unknown(rawValue=\(regErr.rawValue))"
                }
                lastError = "startRegistration: \(label)"
                regState = .failed(label)
                print("[DAT] RegistrationError: \(label) (raw=\(regErr.rawValue))")
            } catch {
                let ns = error as NSError
                lastError = "startRegistration: \(ns.domain)#\(ns.code) \(ns.localizedDescription)"
                regState = .failed("\(ns.domain)#\(ns.code)")
                print("[DAT] non-RegistrationError: domain=\(ns.domain) code=\(ns.code) info=\(ns.userInfo)")
            }
        }
    }

    func handleUrl(_ url: URL) async {
        print("[DAT] handleUrl received: \(url)")
        do {
            let consumed = try await Wearables.shared.handleUrl(url)
            print("[DAT] handleUrl consumed=\(consumed)")
            if !consumed {
                lastError = "handleUrl returned false (URL not recognized)"
            }
        } catch {
            print("[DAT] handleUrl threw: \(error)")
            lastError = "handleUrl: \(error)"
        }
    }

    private func observeRegistrationState() {
        regObserver?.cancel()
        regObserver = Task { @MainActor [weak self] in
            guard let self else { return }
            for await state in Wearables.shared.registrationStateStream() {
                self.regState = Self.mapRegState(state)
            }
        }
    }

    private static func mapRegState(_ s: RegistrationState) -> RegState {
        switch s {
        case .unavailable: return .unavailable
        case .available: return .available
        case .registering: return .registering
        case .registered: return .registered
        @unknown default: return .unknown
        }
    }

    // MARK: - Streaming

    /// Build the DeviceSession + StreamSession and start the BT video stream.
    /// Call this once registration is complete and the WebRTC peer connection
    /// has reached connected, so we don't burn BT bandwidth before the LAN
    /// path is live.
    func armForWebRTC() async {
        guard regState == .registered else {
            lastError = "armForWebRTC: not registered yet"
            return
        }
        guard streamSession == nil else { return }

        // For the mock source, pair + power up the simulated glasses BEFORE
        // wait-for-devices so devicesStream emits the mock device id and
        // AutoDeviceSelector finds an eligible target.
        if source == .mockDevice {
            await prepareMockDevice()
        }

        // Wait up to 8s for at least one device to be enumerated. The
        // devicesStream observer populates deviceIds asynchronously after
        // registration; createSession with AutoDeviceSelector throws
        // noEligibleDevice if it runs against an empty snapshot.
        let waitDeadlineMs: UInt64 = 8_000
        var waitedMs: UInt64 = 0
        while deviceIds.isEmpty && waitedMs < waitDeadlineMs {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waitedMs += 200
        }
        guard !deviceIds.isEmpty else {
            let hint = source == .mockDevice
                ? "(MockDeviceKit not enabled, or pairing failed)"
                : "(BT off, glasses asleep, or Developer Mode disabled?)"
            lastError = "armForWebRTC: no eligible device after \(waitDeadlineMs)ms \(hint)"
            return
        }
        print("[DAT arm] devices=\(deviceIds), creating session…")

        let selector = AutoDeviceSelector(wearables: Wearables.shared)
        // Retry createSession a few times — the eligibility window opens
        // asynchronously after the device's lifecycle settles, especially
        // for mock devices that just transitioned through power/unfold/don.
        var session: DeviceSession?
        var lastCreateError: Error?
        for attempt in 1...5 {
            do {
                session = try Wearables.shared.createSession(deviceSelector: selector)
                break
            } catch {
                lastCreateError = error
                print("[DAT arm] createSession attempt \(attempt) threw: \(error)")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        guard let session else {
            lastError = "createSession (after retries): \(lastCreateError.map { "\($0)" } ?? "unknown")"
            sessionState = .stopped
            return
        }
        self.deviceSession = session
        print("[DAT arm] DeviceSession created, calling start()…")

        do {
            try session.start()
        } catch {
            lastError = "deviceSession.start: \(error)"
            sessionState = .stopped
            print("[DAT arm] DeviceSession.start threw: \(error)")
            return
        }
        print("[DAT arm] DeviceSession started, requesting camera permission…")

        // Camera permission — required before any frames can flow.
        do {
            let status = try await Wearables.shared.requestPermission(.camera)
            print("[DAT arm] camera permission status=\(status)")
            guard status == .granted else {
                lastError = "camera permission denied"
                sessionState = .stopped
                return
            }
        } catch {
            lastError = "requestPermission(.camera): \(error)"
            sessionState = .stopped
            return
        }

        // Build the StreamSession capability and attach it.
        let cfg = StreamSessionConfig(
            videoCodec: .raw,
            resolution: .high,
            frameRate: 24
        )
        let stream: StreamSession?
        do {
            stream = try session.addStream(config: cfg)
        } catch {
            lastError = "addStream: \(error)"
            sessionState = .stopped
            print("[DAT arm] addStream threw: \(error)")
            return
        }
        guard let stream else {
            lastError = "addStream returned nil"
            sessionState = .stopped
            print("[DAT arm] addStream returned nil")
            return
        }
        self.streamSession = stream
        print("[DAT arm] StreamSession capability attached")

        // Attach listeners BEFORE start() so we don't miss the initial
        // .starting → .streaming transition.
        stateToken = stream.statePublisher.listen { [weak self] state in
            print("[DAT stream] state=\(state)")
            Task { @MainActor in self?.handleStreamState(state) }
        }
        frameToken = stream.videoFramePublisher.listen { [weak self] frame in
            // Hot path — DAT's frame thread. Forward synchronously.
            self?.capturer.ingest(frame)
        }

        // Actually start the stream. Without this, the SDK never transitions
        // to .streaming and the videoFramePublisher stays silent.
        sessionState = .starting
        print("[DAT arm] calling stream.start()…")
        await stream.start()
        print("[DAT arm] stream.start() returned; waiting for .streaming state")
    }

    /// Pair + power up a mock Ray-Ban Meta and route its camera to the
    /// iPhone's back camera. Lifecycle calls are scheduled but their state
    /// transitions land asynchronously, so we sleep briefly between steps.
    private func prepareMockDevice() async {
        guard MockDeviceKit.shared.isEnabled else {
            lastError = "prepareMockDevice: MockDeviceKit not enabled (call selectSource(.mockDevice) first)"
            return
        }
        let device: any MockRaybanMeta = mockDevice ?? MockDeviceKit.shared.pairRaybanMeta()
        mockDevice = device
        device.powerOn()
        try? await Task.sleep(nanoseconds: 200_000_000)
        device.unfold()
        try? await Task.sleep(nanoseconds: 200_000_000)
        device.don()
        try? await Task.sleep(nanoseconds: 200_000_000)
        // Route the simulated camera feed from the iPhone's back camera.
        await device.services.camera.setCameraFeed(cameraFacing: .back)
        // Final settle window — the SDK's per-device session needs a moment
        // to flip from .stopped → .running after don() / camera setup.
        try? await Task.sleep(nanoseconds: 500_000_000)
        print("[DAT mock] paired+powered+donned mock RaybanMeta, camera=back, deviceId=\(device.deviceIdentifier)")
    }

    func stop() async {
        // Tear down listeners FIRST so handleStreamState doesn't observe the
        // teardown's `.stopped` and recursively schedule another restart.
        stateToken = nil
        frameToken = nil
        deviceSession?.stop()
        streamSession = nil
        deviceSession = nil
        if let m = mockDevice {
            m.doff()
            m.powerOff()
        }
        sessionState = .stopped
    }

    private func handleStreamState(_ state: StreamSessionState) {
        switch state {
        case .stopping: sessionState = .stopping
        case .stopped:
            sessionState = .stopped
            // Stream went down unexpectedly while we were armed. Schedule a
            // recovery so transient device drops don't wedge the relay.
            scheduleAutoRestart(reason: "stream stopped")
        case .waitingForDevice:
            sessionState = .waitingForDevice
            scheduleAutoRestart(reason: "waitingForDevice")
        case .starting: sessionState = .starting
        case .streaming:
            sessionState = .streaming
            // Healthy state — clear any pending restart attempt counters.
            restartAttemptCount = 0
        case .paused:
            sessionState = .paused
            scheduleAutoRestart(reason: "paused")
        @unknown default: sessionState = .unknown(String(describing: state))
        }
    }

    // MARK: - Auto-restart on transient device loss

    private var restartAttemptCount = 0
    private var pendingRestart: Task<Void, Never>?
    private let maxRestartAttempts = 3

    /// Tear down the StreamSession + DeviceSession and re-arm. The DAT SDK
    /// doesn't auto-resume after `.paused` (hinge close / doff) or after a
    /// transient `.waitingForDevice` flap, and the WebRTC capturer is starved
    /// of frames until we rebuild the session.
    private func scheduleAutoRestart(reason: String) {
        guard pendingRestart == nil else { return }
        guard regState == .registered else { return }
        guard restartAttemptCount < maxRestartAttempts else {
            print("[DAT auto-restart] giving up after \(restartAttemptCount) attempts (last reason=\(reason))")
            return
        }
        restartAttemptCount += 1
        let attempt = restartAttemptCount
        print("[DAT auto-restart] scheduling attempt \(attempt) (reason=\(reason))")
        pendingRestart = Task { @MainActor [weak self] in
            // Backoff so a flapping device doesn't get hammered.
            let delayNs = UInt64(min(8.0, pow(2.0, Double(attempt)))) * 1_000_000_000
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self else { return }
            await self.restart()
            self.pendingRestart = nil
        }
    }

    /// Public restart entry-point: tears down the current session and
    /// re-arms. UI buttons can call this directly to unstick a stuck session.
    func restart() async {
        print("[DAT restart] tearing down…")
        await stop()
        // Brief settle so DAT releases its internal device handles.
        try? await Task.sleep(nanoseconds: 500_000_000)
        print("[DAT restart] re-arming…")
        await armForWebRTC()
    }
}
