import Foundation
import WebRTC
import Vision
import CoreVideo
import CoreML

/// Decides whether the user is doing focused work, given a feed of first-person
/// camera frames from the glasses.
///
/// Pipeline (per processed frame, ~3 fps):
///   1. Run a YOLOv8n CoreML detector (COCO 80 classes) over the camera frame.
///   2. Keep detections whose class is in the "focused work" set
///      (laptop, tv/monitor, keyboard, mouse, book) and whose confidence is
///      above `confidenceThreshold`.
///   3. For each surviving detection, compute the fraction of its bbox that
///      sits inside the central 40% region of the frame. If any qualifying
///      detection has ≥ `centerOverlapMin` of its area in the center → "looking".
///   4. Vote across the last K=3 frames: ≥3/3 above threshold → "looking";
///      ≥3/3 below → "not looking". Symmetric voting kills flicker.
final class GazeAnalyzer: NSObject, RTCVideoRenderer {
    private let queue = DispatchQueue(label: "focus.gaze", qos: .utility)
    private let lock = NSLock()
    private var lastProcessedAt: TimeInterval = 0
    private let minIntervalSec: TimeInterval = 0.3  // ~3 fps

    // MARK: - Tunables

    /// COCO class indices that count as "focused work" cues.
    /// 62 tv, 63 laptop, 64 mouse, 66 keyboard, 73 book.
    var focusClassIds: Set<Int> = [62, 63, 64, 66, 73]

    /// Minimum YOLO confidence to consider a detection.
    var confidenceThreshold: Float = 0.22

    /// Central region of the frame (0..1 image coords) that a detection must
    /// overlap to count as "the user is looking at it." 60% box, centered —
    /// when the user is up close to a laptop the bbox extends well past a
    /// tight center, so be generous here.
    var centerROI: CGRect = CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60)

    /// Required fraction of the detection's bbox that must sit inside `centerROI`.
    var centerOverlapMin: CGFloat = 0.12

    /// Voting window — asymmetric so glances away don't immediately flip OFF
    /// while real focus snaps ON quickly.
    var voteWindow: Int = 5
    var votesToFlipOn: Int = 2
    var votesToFlipOff: Int = 5

    var onSignal: ((Bool) -> Void)?
    var onDebug: ((String) -> Void)?

    // MARK: - State

    private var voteHistory: [Bool] = []
    private var lastEmitted: Bool = false
    private let detector: VNCoreMLModel?

    // MARK: - Init

    override init() {
        self.detector = Self.loadDetector()
        super.init()
        if detector == nil {
            NSLog("[GazeAnalyzer] WARNING: yolov8n.mlpackage failed to load; analyzer will emit false")
        }
    }

    private static func loadDetector() -> VNCoreMLModel? {
        guard let url = Bundle.main.url(forResource: "yolov8n", withExtension: "mlpackage")
            ?? Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc") else {
            NSLog("[GazeAnalyzer] yolov8n model not found in bundle")
            return nil
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let compiled = url.pathExtension == "mlmodelc"
                ? url
                : try MLModel.compileModel(at: url)
            let mlModel = try MLModel(contentsOf: compiled, configuration: config)
            return try VNCoreMLModel(for: mlModel)
        } catch {
            NSLog("[GazeAnalyzer] failed to load yolov8n: \(error)")
            return nil
        }
    }

    // MARK: - RTCVideoRenderer

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let f = frame else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if now - lastProcessedAt < minIntervalSec {
            lock.unlock()
            return
        }
        lastProcessedAt = now
        lock.unlock()

        guard let pixelBuffer = pixelBuffer(from: f) else { return }
        queue.async { [weak self] in
            self?.analyze(pixelBuffer)
        }
    }

    private func pixelBuffer(from frame: RTCVideoFrame) -> CVPixelBuffer? {
        if let cvBuf = frame.buffer as? RTCCVPixelBuffer {
            return cvBuf.pixelBuffer
        }
        return nil
    }

    // MARK: - Pipeline

    private func analyze(_ pixelBuffer: CVPixelBuffer) {
        guard let detector = detector else {
            emit(false, debug: "no-model")
            return
        }

        let request = VNCoreMLRequest(model: detector)
        request.imageCropAndScaleOption = .scaleFit

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            emit(false, debug: "perform-error \(error.localizedDescription)")
            return
        }

        // The NMS-bundled YOLOv8 export emits VNRecognizedObjectObservation via Vision.
        let observations = (request.results as? [VNRecognizedObjectObservation]) ?? []

        // Find the best qualifying detection: focus class, conf above threshold,
        // and bbox-vs-center overlap above threshold. Also collect the strongest
        // arbitrary detection for debug output.
        var bestQualifying: (label: String, conf: Float, overlap: CGFloat)? = nil
        var topAny: (label: String, conf: Float)? = nil

        for obs in observations {
            // Vision's bbox is in normalized 0..1 coords, origin bottom-left.
            // Our centerROI is symmetric so the y-flip doesn't matter here.
            let bbox = obs.boundingBox
            guard let topLabel = obs.labels.first else { continue }
            let conf = topLabel.confidence
            if topAny == nil || conf > (topAny?.conf ?? 0) {
                topAny = (topLabel.identifier, conf)
            }

            guard conf >= confidenceThreshold else { continue }
            // Vision label identifiers are class names ("laptop", "tv", ...).
            guard isFocusClass(topLabel.identifier) else { continue }

            let inter = bbox.intersection(centerROI)
            let bboxArea = max(0.0001, bbox.width * bbox.height)
            let interArea = inter.isNull ? 0 : inter.width * inter.height
            let overlap = interArea / bboxArea
            guard overlap >= centerOverlapMin else { continue }

            if bestQualifying == nil || conf > bestQualifying!.conf {
                bestQualifying = (topLabel.identifier, conf, overlap)
            }
        }

        let raw = bestQualifying != nil
        let dbg: String = {
            if let q = bestQualifying {
                return "FOCUS \(q.label) conf=\(fmt(q.conf)) ovr=\(fmt2(q.overlap)) (n=\(observations.count))"
            } else if let t = topAny {
                return "no-focus top=\(t.label) conf=\(fmt(t.conf)) (n=\(observations.count))"
            } else {
                return "no-detections"
            }
        }()
        emit(raw, debug: dbg)
    }

    private static let focusClassNames: Set<String> = [
        "tv", "tvmonitor", "laptop", "mouse", "keyboard", "book"
    ]

    private func isFocusClass(_ identifier: String) -> Bool {
        Self.focusClassNames.contains(identifier.lowercased())
    }

    // MARK: - Voting

    private func emit(_ raw: Bool, debug: String) {
        voteHistory.append(raw)
        if voteHistory.count > voteWindow {
            voteHistory.removeFirst(voteHistory.count - voteWindow)
        }
        let positives = voteHistory.filter { $0 }.count
        let negatives = voteHistory.count - positives

        var next = lastEmitted
        if !lastEmitted, positives >= votesToFlipOn {
            next = true
        } else if lastEmitted, negatives >= votesToFlipOff {
            next = false
        }
        lastEmitted = next

        let fullDebug = "\(debug) votes=\(positives)+/\(negatives)- → \(next ? "ON" : "OFF")"
        Task { @MainActor [weak self, fullDebug] in
            self?.onSignal?(next)
            self?.onDebug?(fullDebug)
        }
    }

    private func fmt(_ f: Float) -> String { String(format: "%.2f", f) }
    private func fmt2(_ f: CGFloat) -> String { String(format: "%.2f", Double(f)) }
}
