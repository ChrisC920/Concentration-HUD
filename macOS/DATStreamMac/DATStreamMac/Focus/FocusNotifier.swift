import Foundation
import AppKit
import UserNotifications

@MainActor
final class FocusNotifier: NSObject {
    private weak var coordinator: FocusCoordinator?
    private var statusItem: NSStatusItem?
    private var authorized: Bool = false
    private var stateLabel: NSMenuItem?
    private var goalLabel: NSMenuItem?
    private var verdictLabel: NSMenuItem?

    /// Fired when focus is lost (lookingAway or offTopic), once per transition.
    var onFocusLost: (() -> Void)?

    init(coordinator: FocusCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()

        let stateMI = NSMenuItem(title: "State: Unknown", action: nil, keyEquivalent: "")
        stateMI.isEnabled = false
        menu.addItem(stateMI)
        stateLabel = stateMI

        let goalMI = NSMenuItem(title: "Goal: —", action: nil, keyEquivalent: "")
        goalMI.isEnabled = false
        menu.addItem(goalMI)
        goalLabel = goalMI

        let verdictMI = NSMenuItem(title: "AI: —", action: nil, keyEquivalent: "")
        verdictMI.isEnabled = false
        menu.addItem(verdictMI)
        verdictLabel = verdictMI

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Window", action: #selector(openWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for mi in menu.items where mi.action != nil {
            mi.target = self
        }

        item.menu = menu
        statusItem = item
        applyIcon(for: .unknown)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }

        coordinator?.onStateChange = { [weak self] prev, next in
            self?.handleTransition(from: prev, to: next)
        }
    }

    func refresh() {
        guard let coordinator else { return }
        applyIcon(for: coordinator.state)
        stateLabel?.title = "State: \(coordinator.state.displayLabel)"
        let goal = coordinator.goal.isEmpty ? "—" : coordinator.goal
        goalLabel?.title = "Goal: \(goal)"
        let verdict = coordinator.lastGeminiVerdict ?? "—"
        verdictLabel?.title = "AI: \(truncate(verdict, max: 80))"
    }

    private func truncate(_ s: String, max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }

    private func applyIcon(for state: FocusState) {
        guard let button = statusItem?.button else { return }
        let symbolName = "circle.fill"
        let color: NSColor = {
            switch state {
            case .onTask: return .systemGreen
            case .lookingAway, .offTopic: return .systemRed
            case .unknown: return .systemGray
            }
        }()
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: state.displayLabel)?
            .withSymbolConfiguration(cfg)
        button.image = image
    }

    private func handleTransition(from prev: FocusState, to next: FocusState) {
        applyIcon(for: next)
        stateLabel?.title = "State: \(next.displayLabel)"

        guard prev.isOnTask || prev == .unknown else {
            // Only fire once per transition out of on-task / unknown.
            return
        }
        switch next {
        case .lookingAway:
            postNotification(title: "Losing focus", body: "You've been looking away for too long.")
            sendShoot()
            onFocusLost?()
        case .offTopic(let reason):
            postNotification(title: "Losing focus", body: reason)
            sendShoot()
            onFocusLost?()
        default:
            break
        }
    }

    private func sendShoot() {
        guard let url = TurretConfig.shared.url(path: "/shoot") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req).resume()
    }

    private func postNotification(title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    @objc private func openWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
