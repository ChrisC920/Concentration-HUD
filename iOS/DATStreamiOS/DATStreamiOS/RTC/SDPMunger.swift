import Foundation

/// Rewrites an SDP offer to:
/// - keep only H.264 (Constrained Baseline, profile-level-id=42e0…, packetization-mode=1)
///   plus its rtx and the FEC/red codecs
/// - strip VP8, VP9, AV1 entries from the m=video line and their rtpmap/rtcp-fb/fmtp entries
/// - insert b=AS:6000 (kbps) on the m=video line for a 6 Mbps target
///
/// The munged SDP must be re-parsed via RTCSessionDescription before setLocalDescription.
enum SDPMunger {
    static func forceH264AndBitrate(_ sdp: String, bitrateKbps: Int = 6000) -> String {
        var lines = sdp.components(separatedBy: "\r\n")

        // 1) Parse the m=video line, find which payload types are H.264 (and their rtx pairs)
        guard let mIdx = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else { return sdp }

        // Build PT -> codec name and PT -> fmtp params maps from rtpmap/fmtp lines after m=video.
        var ptToCodec: [String: String] = [:]
        var ptToFmtp: [String: String] = [:]
        var rtxToApt: [String: String] = [:]
        let videoSection = lines[(mIdx + 1)...]
        for line in videoSection {
            if line.hasPrefix("a=rtpmap:") {
                // a=rtpmap:96 H264/90000
                let body = String(line.dropFirst("a=rtpmap:".count))
                let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let pt = parts[0]
                let codec = parts[1].split(separator: "/").first.map(String.init) ?? ""
                ptToCodec[pt] = codec
            } else if line.hasPrefix("a=fmtp:") {
                // a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e029
                let body = String(line.dropFirst("a=fmtp:".count))
                let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                ptToFmtp[parts[0]] = parts[1]
                if parts[1].contains("apt=") {
                    let apt = parts[1].split(separator: ";")
                        .compactMap { kv -> String? in
                            let kvParts = kv.split(separator: "=", maxSplits: 1).map(String.init)
                            return (kvParts.count == 2 && kvParts[0] == "apt") ? kvParts[1] : nil
                        }.first
                    if let apt { rtxToApt[parts[0]] = apt }
                }
            }
        }

        // 2) Pick the keeper H.264 PTs: prefer Constrained Baseline (42e0…) with packetization-mode=1.
        let h264PTs = ptToCodec.compactMap { $0.value == "H264" ? $0.key : nil }
        let preferredH264 = h264PTs.first { pt in
            let f = ptToFmtp[pt] ?? ""
            return f.contains("packetization-mode=1") && f.lowercased().contains("profile-level-id=42e0")
        } ?? h264PTs.first { pt in
            (ptToFmtp[pt] ?? "").contains("packetization-mode=1")
        } ?? h264PTs.first

        guard let keepH264 = preferredH264 else { return sdp }

        // Keep: chosen H.264 + its rtx pair + red/ulpfec (FEC codecs, harmless and may help on jittery LAN).
        var keepPTs: Set<String> = [keepH264]
        for (rtxPt, apt) in rtxToApt where apt == keepH264 {
            keepPTs.insert(rtxPt)
        }
        for (pt, codec) in ptToCodec where codec == "red" || codec == "ulpfec" {
            keepPTs.insert(pt)
            for (rtxPt, apt) in rtxToApt where apt == pt { keepPTs.insert(rtxPt) }
        }

        // 3) Rewrite the m=video line keeping only kept PTs in original order.
        let mLine = lines[mIdx]
        let mParts = mLine.split(separator: " ").map(String.init)
        // m=video <port> <proto> <pt1> <pt2> ...
        guard mParts.count >= 4 else { return sdp }
        let header = mParts[0..<3].joined(separator: " ")
        let originalPTs = Array(mParts[3...])
        let keptInOrder = originalPTs.filter { keepPTs.contains($0) }
        lines[mIdx] = (([header] + keptInOrder)).joined(separator: " ")

        // 4) Insert b=AS:<kbps> right after c= line (or right after m= if no c= follows).
        let insertAfter: Int = {
            for i in (mIdx + 1)..<lines.count {
                if lines[i].hasPrefix("m=") { return i - 1 }
                if lines[i].hasPrefix("c=") { return i }
            }
            return mIdx
        }()
        lines.insert("b=AS:\(bitrateKbps)", at: insertAfter + 1)

        // 5) Drop rtpmap/rtcp-fb/fmtp lines whose PT is not kept (only within the video section).
        // Find video section bounds again post-insertion.
        let videoStart = mIdx + 1
        let videoEnd: Int = {
            for i in videoStart..<lines.count where lines[i].hasPrefix("m=") { return i }
            return lines.count
        }()

        let attrPrefixes = ["a=rtpmap:", "a=rtcp-fb:", "a=fmtp:"]
        var filtered: [String] = []
        filtered.reserveCapacity(lines.count)
        filtered.append(contentsOf: lines[0..<videoStart])
        for line in lines[videoStart..<videoEnd] {
            if let prefix = attrPrefixes.first(where: { line.hasPrefix($0) }) {
                let body = String(line.dropFirst(prefix.count))
                let pt = body.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                if !keepPTs.contains(pt) { continue }
            }
            filtered.append(line)
        }
        filtered.append(contentsOf: lines[videoEnd..<lines.count])

        return filtered.joined(separator: "\r\n")
    }
}
