import Foundation
import ScreenCaptureKit
import CoreImage
import AppKit

@MainActor
final class ScreenRelevanceChecker {
    private weak var coordinator: FocusCoordinator?
    private let client = GeminiClient()
    private var task: Task<Void, Never>?
    private let ciContext = CIContext()

    init(coordinator: FocusCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.loop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            let interval = coordinator?.screenCheckIntervalSec ?? 30
            await runOnce()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func runOnce() async {
        guard let coordinator else { return }
        let goal = coordinator.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = coordinator.geminiAPIKey
        guard !goal.isEmpty else { return }
        guard !apiKey.isEmpty else { return }

        do {
            let jpeg = try await captureMainDisplayJPEG()
            let verdict = try await client.evaluate(goal: goal, jpegData: jpeg, apiKey: apiKey)
            coordinator.ingestScreenVerdict(onTask: verdict.onTask, reason: verdict.reason)
        } catch let GeminiError.http(code, _) where [429, 500, 502, 503, 504].contains(code) {
            // Transient — will retry on the next tick. Show a soft hint, not a hard error.
            coordinator.reportError("Gemini busy (HTTP \(code)) — retrying next interval.")
        } catch {
            coordinator.reportError(error.localizedDescription)
        }
    }

    private func captureMainDisplayJPEG() async throws -> Data {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "ScreenRelevanceChecker", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // Downscale target: ~1024px wide.
        let scale: CGFloat = min(1.0, 1024.0 / CGFloat(display.width))
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        config.capturesAudio = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return try jpegData(from: cgImage, quality: 0.7)
    }

    private func jpegData(from cgImage: CGImage, quality: CGFloat) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .jpeg,
                                               properties: [.compressionFactor: quality]) else {
            throw NSError(domain: "ScreenRelevanceChecker", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "JPEG encoding failed"])
        }
        return data
    }
}
