import Foundation
import ScreenCaptureKit
import CoreImage
import AppKit
import Vision

/// Periodically captures the current display and produces two reference signals
/// that GazeAnalyzer matches camera frames against:
///   1. A 32×32 grayscale fingerprint for normalized cross-correlation (NCC).
///   2. A Vision feature print embedding for learned-similarity scoring.
final class ScreenHashStore: @unchecked Sendable {
    static let shared = ScreenHashStore()

    static let hashSize: Int = 32

    struct Reference {
        let grid: [Float]                        // hashSize×hashSize raw 0..1 grayscale
        let mean: Float
        let stdDev: Float
        let featurePrint: VNFeaturePrintObservation?
        /// 4×4 grid of patch-level featureprints (16 total). Lets us match a
        /// camera frame against any local region of the screen, not just the
        /// whole screen — much more robust when the camera only sees a fragment.
        let patchFeaturePrints: [VNFeaturePrintObservation]
        let capturedAt: Date
    }

    private let lock = NSLock()
    private var _latest: Reference?
    private var _previousGrid: [Float]?       // for screen-motion tracking
    private var _screenMotion: Float = 0      // mean abs diff between consecutive grids (0..1)
    private var task: Task<Void, Never>?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Mean abs frame-to-frame change in the screen grid (0..1). Higher means
    /// the screen has been changing between captures. Static screens trend toward 0.
    var screenMotion: Float {
        lock.lock(); defer { lock.unlock() }
        return _screenMotion
    }

    var latest: (ref: Reference, age: TimeInterval)? {
        lock.lock(); defer { lock.unlock() }
        guard let r = _latest else { return nil }
        return (r, Date().timeIntervalSince(r.capturedAt))
    }

    private func store(_ ref: Reference) {
        lock.lock()
        // Compute screen motion against the previous grid before replacing.
        if let prev = _previousGrid, prev.count == ref.grid.count {
            var acc: Float = 0
            for i in 0..<prev.count { acc += abs(prev[i] - ref.grid[i]) }
            _screenMotion = acc / Float(prev.count)
        }
        _previousGrid = _latest?.grid
        _latest = ref
        lock.unlock()
    }

    func start(intervalSec: TimeInterval = 5.0) {
        guard task == nil else { return }
        task = Task.detached { [weak self] in
            await self?.loop(intervalSec: intervalSec)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func loop(intervalSec: TimeInterval) async {
        while !Task.isCancelled {
            await captureOnce()
            try? await Task.sleep(nanoseconds: UInt64(intervalSec * 1_000_000_000))
        }
    }

    private func captureOnce() async {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale: CGFloat = min(1.0, 512.0 / CGFloat(display.width))
            config.width = max(128, Int(CGFloat(display.width) * scale))
            config.height = max(128, Int(CGFloat(display.height) * scale))
            config.showsCursor = false

            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if let ref = makeReference(from: cg) {
                store(ref)
            }
        } catch {
            // Soft failure — analyzer falls back to gates-only.
        }
    }

    func makeReference(from cg: CGImage) -> Reference? {
        guard let grid = grayscaleGrid(cg, n: ScreenHashStore.hashSize, centerInsetPct: 0.1) else { return nil }
        let mean = grid.reduce(0, +) / Float(grid.count)
        var sq: Float = 0
        for v in grid { let d = v - mean; sq += d * d }
        let std = (sq / Float(grid.count)).squareRoot()

        let fp = featurePrint(for: cg)
        let patches = patchFeaturePrints(for: cg, gridDim: 4)

        return Reference(grid: grid, mean: mean, stdDev: std,
                         featurePrint: fp, patchFeaturePrints: patches,
                         capturedAt: Date())
    }

    /// Splits the screenshot into a gridDim×gridDim grid (default 4×4 = 16
    /// patches), and produces a featureprint for each. Used for local-region
    /// matching against camera fragments.
    func patchFeaturePrints(for cg: CGImage, gridDim: Int) -> [VNFeaturePrintObservation] {
        var out: [VNFeaturePrintObservation] = []
        let w = cg.width, h = cg.height
        let pw = w / gridDim
        let ph = h / gridDim
        guard pw > 32, ph > 32 else { return out }
        for gy in 0..<gridDim {
            for gx in 0..<gridDim {
                let rect = CGRect(x: gx * pw, y: gy * ph, width: pw, height: ph)
                guard let patchCG = cg.cropping(to: rect) else { continue }
                if let fp = featurePrint(for: patchCG) {
                    out.append(fp)
                }
            }
        }
        return out
    }

    func grayscaleGrid(_ cg: CGImage, n: Int, centerInsetPct: CGFloat) -> [Float]? {
        let ci = CIImage(cgImage: cg)
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let inset = centerInsetPct
        let crop = CGRect(x: w * inset, y: h * inset,
                          width: w * (1 - 2 * inset), height: h * (1 - 2 * inset))
        let cropped = ci.cropped(to: crop)
        let gray = cropped.applyingFilter("CIPhotoEffectMono")
        let s = CGFloat(n) / max(crop.width, crop.height)
        let scaled = gray.transformed(by: CGAffineTransform(scaleX: s, y: s))

        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        ciContext.render(scaled,
                         toBitmap: &bytes,
                         rowBytes: n * 4,
                         bounds: CGRect(x: scaled.extent.minX, y: scaled.extent.minY,
                                        width: CGFloat(n), height: CGFloat(n)),
                         format: .RGBA8,
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        var grid = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) { grid[i] = Float(bytes[i * 4]) / 255.0 }
        return grid
    }

    func featurePrint(for cg: CGImage) -> VNFeaturePrintObservation? {
        let req = VNGenerateImageFeaturePrintRequest()
        req.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([req])
            return req.results?.first as? VNFeaturePrintObservation
        } catch {
            return nil
        }
    }
}

/// Normalized cross-correlation between two equal-length, equal-shape grids.
/// Returns a value in [-1, 1]; >0.5 is a strong match. Exposure/brightness
/// invariant because both vectors are mean-centered and unit-normalized.
func ncc(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    let ma = a.reduce(0, +) / Float(a.count)
    let mb = b.reduce(0, +) / Float(b.count)
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count {
        let da = a[i] - ma
        let db = b[i] - mb
        dot += da * db
        na += da * da
        nb += db * db
    }
    let denom = (na.squareRoot()) * (nb.squareRoot())
    return denom > 0 ? dot / denom : 0
}
