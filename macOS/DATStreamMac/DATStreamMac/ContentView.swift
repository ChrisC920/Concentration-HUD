import SwiftUI
import Combine
import AVKit
import DATSignaling

struct ContentView: View {
    @State private var advertiser = BonjourAdvertiser()
    @State private var rtcProbe = RTCFactoryProbe()
    @State private var rtc = RTCConnection()
    @State private var focus = FocusCoordinator()
    @State private var gaze = GazeAnalyzer()
    @State private var screenChecker: ScreenRelevanceChecker?
    @State private var notifier: FocusNotifier?
    @State private var clipFetcher = TurretClipFetcher()
    @State private var didWireFocus = false
    @State private var liveTrackTick: Int = 0
    @State private var showSettings = false
    private let pollTimer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionCard
                    focusCard
                    if rtc.liveTrack != nil {
                        videoCard
                    }
                    turretClipCard
                }
                .padding(20)
            }
        }
        .frame(minWidth: 540, minHeight: 600)
        .onAppear {
            // Auto-advertise on launch so connection is one click on the iPhone.
            advertiser.start()
            rtcProbe.run()
            rtc.bind(channel: advertiser.channel)
            wireFocusOnce()
        }
        .onReceive(pollTimer) { _ in
            if rtc.liveTrack != nil && liveTrackTick == 0 {
                liveTrackTick = 1
            }
            notifier?.refresh()
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
    }

    private func wireFocusOnce() {
        guard !didWireFocus else { return }
        didWireFocus = true
        let checker = ScreenRelevanceChecker(coordinator: focus)
        focus.bindScreenChecker(checker)
        screenChecker = checker

        gaze.onSignal = { [focus] looking in
            focus.ingestGazeSignal(isLookingAtScreen: looking)
        }
        gaze.onDebug = { [focus] s in
            focus.updateGazeDebug(s)
        }
        rtc.attachExtraRenderer(gaze)

        let n = FocusNotifier(coordinator: focus)
        n.install()
        n.onFocusLost = { [clipFetcher] in
            clipFetcher.fetchAfterShoot()
        }
        notifier = n
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Focus").font(.headline)
                headerSubtitle
            }
            Spacer(minLength: 12)
            headerStatusChips
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var headerSubtitle: some View {
        Text(headerSubtitleText)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var headerSubtitleText: String {
        if !focus.isRunning { return "Idle" }
        switch focus.state {
        case .onTask: return "Focused"
        case .lookingAway: return "Distracted — looking away"
        case .offTopic(let r): return r
        case .unknown: return "Getting signal…"
        }
    }

    @ViewBuilder
    private var headerStatusChips: some View {
        HStack(spacing: 8) {
            if focus.isRunning {
                gazeChip
                aiChip
            }
        }
    }

    @ViewBuilder
    private var gazeChip: some View {
        let label = focus.lastGazeLabel ?? "—"
        let onScreen = label.lowercased().contains("laptop")
            || label.lowercased().contains("monitor")
            || label.lowercased().contains("keyboard")
            || label.lowercased().contains("book")
        chip(icon: "eye",
             text: label,
             tint: onScreen ? .green : .orange)
            .help("Gaze: \(label)")
    }

    @ViewBuilder
    private var aiChip: some View {
        let verdict = focus.lastGeminiVerdict ?? "Analyzing screen…"
        let isOnTask = focus.lastGeminiVerdict?.hasPrefix("On-task") ?? false
        chip(icon: "sparkles",
             text: shortVerdict(verdict),
             tint: focus.lastGeminiVerdict == nil ? .secondary
                                                  : (isOnTask ? .green : .orange))
            .help(verdict)
    }

    private func shortVerdict(_ s: String) -> String {
        // Drop the leading "On-task: " / "Off-task: " prefix; keep up to ~36 chars.
        let core: String = {
            if let r = s.range(of: ": ") { return String(s[r.upperBound...]) }
            return s
        }()
        return core.count > 36 ? String(core.prefix(35)) + "…" : core
    }

    private func chip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text(text)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.12)))
    }

    // MARK: - Connection card

    private var connectionCard: some View {
        let connected = (rtc.state == .connected)
        let waitingForPhone = !connected
        return HStack(spacing: 12) {
            Image(systemName: connected ? "checkmark.circle.fill" : "iphone.gen3.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(connected ? .green : .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(connected ? "Glasses connected" : "Waiting for iPhone")
                    .font(.headline)
                Text(connected
                     ? "Your camera feed is live."
                     : "Open the iPhone app on the same Wi-Fi and tap your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if waitingForPhone {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12)
                        .fill((connected ? Color.green : Color.blue).opacity(0.08)))
    }

    // MARK: - Focus card

    private var focusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "target")
                Text("Focus session").font(.headline)
                Spacer()
                statePill
            }

            TextField("What are you working on?", text: $focus.goal)
                .textFieldStyle(.roundedBorder)
                .disabled(focus.isRunning)

            primaryActionButton

            Button {
                sendShootTest()
                clipFetcher.fetchAfterShoot()
            } label: {
                Label("Test /shoot POST", systemImage: "paperplane")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            .buttonStyle(.bordered)

            if focus.geminiAPIKey.isEmpty {
                Label("Add your Gemini API key in Settings to enable screen focus checks.",
                      systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.07)))
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if focus.isRunning {
            Button(role: .destructive) { focus.stop() } label: {
                Label("End session", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
        } else {
            Button {
                focus.start()
            } label: {
                Label("Start focus session", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(focus.goal.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var statePill: some View {
        let (color, text): (Color, String) = {
            if !focus.isRunning { return (.secondary, "Idle") }
            switch focus.state {
            case .onTask: return (.green, "On task")
            case .lookingAway: return (.red, "Looking away")
            case .offTopic: return (.red, "Off topic")
            case .unknown: return (.secondary, "—")
            }
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - Video preview

    private var videoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live preview")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black)
                MetalVideoView(track: rtc.liveTrack)
                    .id(liveTrackTick)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .aspectRatio(9.0/16.0, contentMode: .fit)
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Settings

    private var settingsSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Settings").font(.title3.bold())
                    Spacer()
                    Button("Done") { showSettings = false }
                        .keyboardShortcut(.defaultAction)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Gemini API key").font(.subheadline)
                    SecureField("Paste key", text: $focus.geminiAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(focus.isRunning)
                    Text("Used to evaluate whether your screen content matches your goal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Turret host").font(.subheadline)
                    TextField("https://turret.tailnet.ts.net", text: Bindable(TurretConfig.shared).host)
                        .textFieldStyle(.roundedBorder)
                    Text("Full URL (https://…) for Tailscale Serve, or bare hostname/IP for plain HTTP on port 8787. Examples: \"https://turret.tail123.ts.net\", \"turret.local\", \"100.99.40.5\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                presetSection
                Divider()
                timingsSection

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(width: 460, height: 540)
    }

    @ViewBuilder
    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sensitivity").font(.subheadline.bold())
            Text("Choose how quickly the monitor flags lost focus.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: $focus.preset) {
                ForEach(FocusCoordinator.Preset.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(focus.preset.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var timingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trigger timings").font(.subheadline.bold())

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Look-away timeout")
                    Spacer()
                    Text("\(timingDisplay(focus.lookAwayTimeoutSec))")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $focus.lookAwayTimeoutSec, in: 1...120, step: 1)
                Text("How long the user can look away before being flagged as distracted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Screen-check interval")
                    Spacer()
                    Text("\(timingDisplay(focus.screenCheckIntervalSec))")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $focus.screenCheckIntervalSec, in: 2...300, step: 1)
                Text("How often Gemini analyzes the screen to confirm on-task content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Reset to preset") {
                    if let t = focus.preset.timings {
                        focus.lookAwayTimeoutSec = t.0
                        focus.screenCheckIntervalSec = t.1
                    }
                }
                .disabled(focus.preset == .custom)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var turretClipCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "video.circle")
                Text("Turret capture").font(.headline)
                Spacer()
                Text(clipFetcher.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let url = clipFetcher.latestClip {
                VideoPlayer(player: AVPlayer(url: url))
                    .id(clipFetcher.clipVersion)
                    .frame(height: 240)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Clear") { clipFetcher.clear() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                Text("No clip yet. One will appear here when the turret captures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.07)))
    }

    private func sendShootTest() {
        guard let url = TurretConfig.shared.url(path: "/shoot") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req).resume()
    }

    private func timingDisplay(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let r = s % 60
        return r == 0 ? "\(m)m" : "\(m)m \(r)s"
    }
}

#Preview { ContentView() }
