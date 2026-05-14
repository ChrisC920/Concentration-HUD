import SwiftUI
import Combine
import DATSignaling

struct ContentView: View {
    @Bindable var dat: DATSessionController

    @State private var browser = BonjourBrowser()
    @State private var channel = SignalingChannel()
    @State private var rtcProbe = RTCFactoryProbe()
    @State private var rtc = RTCConnection()
    @State private var pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var didAutoConnect = false
    @State private var didAutoStream = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                statusBanner
                glassesCard
                primaryActions
                Spacer()
            }
            .padding(20)
            .navigationTitle("DATStream")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            browser.start()
            rtcProbe.run()
        }
        .onReceive(pollTimer) { _ in
            autoConnectIfPossible()
        }
        .onChange(of: browser.peers.count) { _, _ in
            autoConnectIfPossible()
        }
    }

    // MARK: - Auto-connect

    private func autoConnectIfPossible() {
        guard !didAutoConnect, !channelOpen, let peer = browser.peers.first else { return }
        didAutoConnect = true
        channel.connect(to: peer.endpoint)
        rtc.bind(channel: channel)
    }

    // MARK: - Status banner

    @ViewBuilder
    private var statusBanner: some View {
        let (icon, title, subtitle, tint) = bannerSummary()
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if showsBannerSpinner {
                ProgressView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(tint.opacity(0.1)))
    }

    private var showsBannerSpinner: Bool {
        if rtc.state == .connected && dat.sessionState == .streaming { return false }
        if browser.peers.isEmpty { return true }
        if !channelOpen { return true }
        if rtc.state != .idle && rtc.state != .connected { return true }
        return false
    }

    private func bannerSummary() -> (String, String, String?, Color) {
        if rtc.state == .connected && dat.sessionState == .streaming {
            return ("dot.radiowaves.left.and.right", "Streaming to your Mac",
                    "Focus session is active.", .green)
        }
        if rtc.state == .connected {
            return ("link", "Connected", "Starting stream…", .green)
        }
        if case .failed = rtc.state {
            return ("exclamationmark.triangle.fill", "Connection failed",
                    "Tap Stop, then Start Streaming again.", .red)
        }
        if dat.regState != .registered && dat.source == .realGlasses {
            return ("person.crop.circle.badge.questionmark", "Register with Meta AI",
                    "Required to use real glasses.", .orange)
        }
        if channelOpen {
            return ("link", "Connected to Mac",
                    dat.deviceIds.isEmpty && dat.source == .realGlasses
                        ? "Power on your glasses to begin."
                        : "Tap Start Streaming.", .blue)
        }
        if !browser.peers.isEmpty {
            return ("laptopcomputer", "Mac found",
                    "Connecting…", .blue)
        }
        return ("magnifyingglass", "Looking for your Mac",
                "Open the Mac app on the same Wi-Fi.", .secondary)
    }

    // MARK: - Glasses card

    @ViewBuilder
    private var glassesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "eyeglasses")
                Text("Glasses").font(.headline)
                Spacer()
                glassesPill
            }

            Picker("Source", selection: Binding(
                get: { dat.source },
                set: { dat.selectSource($0) }
            )) {
                ForEach(DATSessionController.Source.allCases) { src in
                    Text(src.label).tag(src)
                }
            }
            .pickerStyle(.segmented)
            .disabled(rtc.state != .idle)

            if dat.source == .realGlasses && dat.regState != .registered {
                Button {
                    dat.startRegistration()
                } label: {
                    Label("Register with Meta AI", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(dat.regState == .registering)
            }

            if let err = dat.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    @ViewBuilder
    private var glassesPill: some View {
        let (color, text): (Color, String) = {
            if dat.source == .mockDevice { return (.blue, "Mock") }
            switch dat.regState {
            case .registered:
                if dat.deviceIds.isEmpty { return (.orange, "No device") }
                return (.green, "Ready")
            case .registering: return (.secondary, "Registering…")
            case .available: return (.orange, "Tap Register")
            case .unavailable: return (.red, "Meta AI missing")
            case .failed: return (.red, "Failed")
            case .unknown: return (.secondary, "Checking…")
            }
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    // MARK: - Actions

    @ViewBuilder
    private var primaryActions: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    rtc.attach(capturer: dat.capturer)
                    await rtc.startOffer()
                    await dat.armForWebRTC()
                }
            } label: {
                Label(rtc.state == .connected ? "Streaming" : "Start streaming",
                      systemImage: rtc.state == .connected ? "dot.radiowaves.left.and.right" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canStartStreaming)

            if rtc.state != .idle {
                Button {
                    Task { await dat.restart() }
                } label: {
                    Label("Restart capture", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(role: .destructive) {
                    rtc.teardown(reason: "user")
                    Task { await dat.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private var canStartStreaming: Bool {
        channel.state == .open
            && rtc.state == .idle
            && dat.regState == .registered
            && (dat.source == .mockDevice || !dat.deviceIds.isEmpty)
    }

    // MARK: - Helpers

    private var channelOpen: Bool {
        if case .open = channel.state { return true }
        return false
    }
}

#Preview { ContentView(dat: DATSessionController()) }
