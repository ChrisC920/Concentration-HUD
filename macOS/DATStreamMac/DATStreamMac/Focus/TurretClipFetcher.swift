import Foundation
import Observation

/// Pulls a short MP4 clip from the turret's HTTP server after a /shoot fires.
///
/// Pi serves the clip at `http://turret.local:8787/last_clip.mp4`. We probe
/// readiness with a tiny ranged GET (Range: bytes=0-0) — many minimal HTTP
/// servers (Python http.server, some quick FastAPI handlers) return 501 for
/// HEAD, so HEAD is unreliable. A 200/206 with a non-empty body means the
/// file exists and has at least one byte; a stable Content-Length / Content-
/// Range across two probes means it's done growing.
@MainActor
@Observable
final class TurretClipFetcher {
    private(set) var latestClip: URL?
    private(set) var clipVersion: Int = 0
    private(set) var status: String = "idle"
    private(set) var lastError: String? = nil

    private var clipURL: URL {
        TurretConfig.shared.url(path: "/last_clip.mp4")
            ?? URL(string: "http://turret.local:8787/last_clip.mp4")!
    }
    private let pollInterval: TimeInterval = 1.0
    private let maxAttempts: Int = 30
    private var inFlight: Task<Void, Never>?

    /// Per-call session: avoids URLSession.shared caching a dead IPv6 endpoint
    /// across attempts, and disables waitsForConnectivity so a failed v6
    /// connect returns fast and lets the next attempt try v4.
    private func makeSession(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: cfg)
    }

    func fetchAfterShoot() {
        if inFlight != nil { return }
        inFlight = Task { [weak self] in
            await self?.run()
            self?.inFlight = nil
        }
    }

    private func run() async {
        // 10s head start so the Pi has finished overwriting last_clip.mp4
        // with the *new* recording before we start probing — otherwise we
        // race and pull the previous clip.
        for remaining in stride(from: 10, through: 1, by: -1) {
            if Task.isCancelled { return }
            status = "waiting for turret to record… (\(remaining)s)"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        status = "waiting for clip…"

        var lastSize: Int64 = -1
        var stableCount = 0

        for attempt in 1...maxAttempts {
            if Task.isCancelled { return }
            let probe = await probeSize()
            if let size = probe {
                let isStable: Bool = (size == -2 && lastSize == -2) || (size > 0 && size == lastSize)
                stableCount = isStable ? stableCount + 1 : 0
                lastSize = size
                if stableCount >= 1 {
                    await download()
                    return
                }
            }
            if let err = lastError {
                status = "waiting… (\(attempt)/\(maxAttempts)) — \(err)"
            } else {
                status = "waiting for clip… (\(attempt)/\(maxAttempts))"
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        status = lastError.map { "no clip received — \($0)" } ?? "no clip received"
    }

    /// Returns the file's full byte length (from Content-Range) when known,
    /// `-2` when we got a successful response without a length, or nil on
    /// failure. Uses a 1-byte ranged GET so any server that supports GET will
    /// work, including ones that 501 on HEAD.
    private func probeSize() async -> Int64? {
        var req = URLRequest(url: clipURL)
        req.httpMethod = "GET"
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.setValue("close", forHTTPHeaderField: "Connection")
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = makeSession(timeout: 4)
        defer { session.invalidateAndCancel() }
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            switch http.statusCode {
            case 206:
                // Content-Range: bytes 0-0/12345  → total is after the slash.
                if let cr = http.value(forHTTPHeaderField: "Content-Range"),
                   let slash = cr.firstIndex(of: "/"),
                   let total = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)) {
                    lastError = nil
                    return total > 0 ? total : -2
                }
                lastError = nil
                return -2
            case 200:
                // Server ignored Range and sent the whole file (or a chunk).
                // Content-Length on a 200 is the full size.
                if let len = http.value(forHTTPHeaderField: "Content-Length"), let n = Int64(len), n > 0 {
                    lastError = nil
                    return n
                }
                lastError = nil
                return data.isEmpty ? -2 : Int64(data.count)
            case 404:
                lastError = "clip not on turret yet (404)"
                return nil
            default:
                lastError = "probe HTTP \(http.statusCode)"
                return nil
            }
        } catch {
            lastError = "probe error: \(error.localizedDescription)"
            return nil
        }
    }

    private func download() async {
        status = "downloading…"
        var req = URLRequest(url: clipURL)
        req.setValue("close", forHTTPHeaderField: "Connection")
        req.timeoutInterval = 30
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = makeSession(timeout: 30)
        defer { session.invalidateAndCancel() }
        do {
            let (tempURL, resp) = try await session.download(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                status = "download failed (HTTP \(code))"
                return
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("turret-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).mp4")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            latestClip = dest
            clipVersion &+= 1
            status = "ready"
        } catch {
            status = "download failed: \(error.localizedDescription)"
        }
    }

    func clear() {
        if let url = latestClip {
            try? FileManager.default.removeItem(at: url)
        }
        latestClip = nil
        status = "idle"
    }
}
