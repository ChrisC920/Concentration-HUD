import Foundation
import Observation

/// Single source of truth for the turret's HTTP base URL. Accepts:
///   - a full URL with scheme: "https://turret.taile2393d.ts.net"
///   - a bare hostname:        "turret.local"        (assumes http://host:8787)
///   - a bare IP:              "100.99.40.5"          (assumes http://ip:8787)
@MainActor
@Observable
final class TurretConfig {
    static let shared = TurretConfig()

    private let key = "turret.host"
    private let defaultHost = "turret.local"
    private let defaultPort = 8787

    var host: String {
        didSet {
            let trimmed = host.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(trimmed, forKey: key)
            }
        }
    }

    private init() {
        self.host = UserDefaults.standard.string(forKey: key) ?? "turret.local"
    }

    private var effective: String {
        let h = host.trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? defaultHost : h
    }

    func url(path: String) -> URL? {
        let raw = effective
        // 1. Already a full URL with scheme.
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            return URL(string: raw.trimmingTrailingSlash() + path)
        }
        // 2. Bare host or IP. Bracket bare IPv6 literals.
        let hostPart: String = {
            if raw.contains(":") && !raw.hasPrefix("[") && !raw.contains("]") {
                // Could be IPv6 (no brackets) or host:port. Heuristic: if there's
                // exactly one ':' and the part after parses as an Int, treat as host:port.
                let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2, Int(parts[1]) != nil {
                    return raw  // already host:port, leave alone
                }
                return "[\(raw)]"  // IPv6 literal
            }
            return raw
        }()
        let portSuffix = hostPart.contains(":") ? "" : ":\(defaultPort)"
        return URL(string: "http://\(hostPart)\(portSuffix)\(path)")
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
