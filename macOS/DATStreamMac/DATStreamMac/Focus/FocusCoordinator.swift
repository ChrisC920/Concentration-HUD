import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class FocusCoordinator {
    enum Preset: String, CaseIterable, Identifiable {
        case relaxed, moderate, strict, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .relaxed: return "Relaxed"
            case .moderate: return "Moderate"
            case .strict: return "Strict"
            case .custom: return "Custom"
            }
        }
        var subtitle: String {
            switch self {
            case .relaxed: return "Long grace periods. Forgiving."
            case .moderate: return "Balanced timings."
            case .strict: return "Near-instant flagging."
            case .custom: return "Your own timings."
            }
        }
        /// (lookAwayTimeoutSec, screenCheckIntervalSec)
        var timings: (Double, Double)? {
            switch self {
            case .relaxed:  return (15, 60)
            case .moderate: return (5, 20)
            case .strict:   return (2, 5)
            case .custom:   return nil
            }
        }
    }

    var goal: String = ""
    var lookAwayTimeoutSec: Double = 3 { didSet { syncPresetFromTimings() } }
    var screenCheckIntervalSec: Double = 15 { didSet { syncPresetFromTimings() } }
    var preset: Preset = .moderate {
        didSet {
            guard preset != oldValue, let t = preset.timings else { return }
            applyingPreset = true
            lookAwayTimeoutSec = t.0
            screenCheckIntervalSec = t.1
            applyingPreset = false
            UserDefaults.standard.set(preset.rawValue, forKey: "focus.preset")
        }
    }
    private var applyingPreset = false
    var geminiAPIKey: String = UserDefaults.standard.string(forKey: "gemini.apiKey") ?? ""

    private(set) var state: FocusState = .unknown
    private(set) var lastGeminiVerdict: String? = nil
    private(set) var lastError: String? = nil
    private(set) var isRunning: Bool = false
    private(set) var lastGazeDebug: String? = nil
    /// Human-readable label of where the user is looking, derived from the
    /// gaze analyzer (e.g. "Looking at laptop", "Looking away"). nil before
    /// the first signal.
    private(set) var lastGazeLabel: String? = nil
    /// Rolling history of the last ~60 gaze debug lines + state transitions,
    /// for offline diagnosis. Stamped with state so the user can see at what
    /// numbers a wrong verdict was emitted.
    private(set) var debugHistory: [String] = []
    private let debugHistoryMax: Int = 60

    private var lastGazeOnScreenAt: Date? = nil
    private var lastGazeSignal: Bool? = nil
    private var lastScreenVerdictOnTask: Bool? = nil
    private var lastScreenVerdictReason: String? = nil

    private var graceTimer: Timer?
    private weak var screenChecker: ScreenRelevanceChecker?

    var onStateChange: ((FocusState, FocusState) -> Void)?

    init() {
        let saved = UserDefaults.standard.string(forKey: "focus.preset")
            .flatMap(Preset.init(rawValue:)) ?? .moderate
        applyingPreset = true
        preset = saved
        if let t = saved.timings {
            lookAwayTimeoutSec = t.0
            screenCheckIntervalSec = t.1
        }
        applyingPreset = false
    }

    func bindScreenChecker(_ checker: ScreenRelevanceChecker) {
        self.screenChecker = checker
    }

    /// If the user nudges a stepper to a value that doesn't match the active
    /// preset's timings, flip the preset to `.custom`. Skipped while we're
    /// programmatically applying preset values.
    private func syncPresetFromTimings() {
        guard !applyingPreset else { return }
        if let t = preset.timings,
           abs(t.0 - lookAwayTimeoutSec) < 0.001,
           abs(t.1 - screenCheckIntervalSec) < 0.001 {
            return
        }
        if preset != .custom {
            applyingPreset = true
            preset = .custom
            applyingPreset = false
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        // Reset signals so a fresh session waits for new data.
        lastGazeOnScreenAt = nil
        lastGazeSignal = nil
        lastScreenVerdictOnTask = nil
        lastScreenVerdictReason = nil

        if !geminiAPIKey.isEmpty {
            UserDefaults.standard.set(geminiAPIKey, forKey: "gemini.apiKey")
            screenChecker?.start()
        } else {
            lastError = "Gemini API key not set — only gaze monitoring will run."
        }

        // Start the screen fingerprint loop so GazeAnalyzer can match camera
        // regions against the live display content. Fast refresh during testing.
        ScreenHashStore.shared.start(intervalSec: 2.0)

        startGraceTimer()
        recompute()
    }

    func updateGazeDebug(_ s: String) {
        lastGazeDebug = s
        lastGazeLabel = Self.friendlyGazeLabel(from: s)
        let stamp = Self.timestampFormatter.string(from: Date())
        let line = "\(stamp) [\(state.displayLabel)] \(s)"
        debugHistory.append(line)
        if debugHistory.count > debugHistoryMax {
            debugHistory.removeFirst(debugHistory.count - debugHistoryMax)
        }
    }

    /// Converts a GazeAnalyzer debug line into a friendly label.
    /// Lines look like: "FOCUS laptop conf=0.74 ovr=0.42 (n=5) votes=2+/1- → ON"
    /// or "no-focus top=bed conf=0.61 (n=4) votes=0+/3- → OFF" or "no-detections …".
    private static func friendlyGazeLabel(from debug: String) -> String {
        if let range = debug.range(of: #"^FOCUS\s+(\S+)"#, options: .regularExpression) {
            let label = debug[range].split(separator: " ").last.map(String.init) ?? "screen"
            return "Looking at \(prettyClass(label))"
        }
        if debug.hasPrefix("no-focus") {
            // Try to surface what the camera *did* see, e.g. "bed", "person", "couch".
            if let topRange = debug.range(of: #"top=(\S+)"#, options: .regularExpression) {
                let raw = debug[topRange].dropFirst("top=".count)
                return "Looking at \(prettyClass(String(raw)))"
            }
            return "Looking away"
        }
        if debug.hasPrefix("no-detections") || debug.hasPrefix("no-model") || debug.contains("perform-error") {
            return "Looking away"
        }
        return "—"
    }

    private static func prettyClass(_ raw: String) -> String {
        switch raw.lowercased() {
        case "tv", "tvmonitor": return "monitor"
        case "laptop": return "laptop"
        case "keyboard": return "keyboard"
        case "mouse": return "mouse"
        case "book": return "book"
        case "bed": return "bed"
        case "couch", "sofa": return "couch"
        case "person": return "someone"
        case "cell phone", "cellphone": return "phone"
        default: return raw.lowercased()
        }
    }

    func copyDebugHistoryToPasteboard() {
        let text = debugHistory.joined(separator: "\n")
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func stop() {
        guard isRunning else { return }
        isRunning = false
        graceTimer?.invalidate()
        graceTimer = nil
        screenChecker?.stop()
        transition(to: .unknown)
    }

    func ingestGazeSignal(isLookingAtScreen: Bool) {
        lastGazeSignal = isLookingAtScreen
        if isLookingAtScreen {
            lastGazeOnScreenAt = Date()
        }
        recompute()
    }

    func ingestScreenVerdict(onTask: Bool, reason: String) {
        lastScreenVerdictOnTask = onTask
        lastScreenVerdictReason = reason
        lastGeminiVerdict = "\(onTask ? "On-task" : "Off-task"): \(reason)"
        recompute()
    }

    func reportError(_ message: String) {
        lastError = message
    }

    // MARK: - Internals

    private func startGraceTimer() {
        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
    }

    private func recompute() {
        guard isRunning else {
            transition(to: .unknown)
            return
        }

        // Look-away dominates: if gaze hasn't been on screen recently, flag.
        let now = Date()
        let lookAwayElapsed: TimeInterval = {
            guard let last = lastGazeOnScreenAt else { return .infinity }
            return now.timeIntervalSince(last)
        }()

        if lookAwayElapsed > lookAwayTimeoutSec {
            // Only flag if we have at least one gaze signal so far.
            if lastGazeSignal != nil {
                transition(to: .lookingAway)
                return
            }
        }

        // Gaze recently on screen; defer to screen verdict.
        if let onTask = lastScreenVerdictOnTask, !onTask {
            transition(to: .offTopic(reason: lastScreenVerdictReason ?? "Off-topic content"))
            return
        }

        if lastGazeSignal == true && lastScreenVerdictOnTask == true {
            transition(to: .onTask)
            return
        }

        // Not enough info yet (e.g., waiting for first Gemini verdict).
        if lastScreenVerdictOnTask == nil && lastGazeSignal == true {
            // Gaze is fine but Gemini hasn't replied yet; treat as on-task tentatively.
            transition(to: .onTask)
            return
        }

        transition(to: .unknown)
    }

    private func transition(to next: FocusState) {
        guard next != state else { return }
        let prev = state
        state = next
        onStateChange?(prev, next)
    }
}
