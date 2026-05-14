import Foundation

struct GeminiVerdict {
    let onTask: Bool
    let reason: String
}

enum GeminiError: Error, LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case badResponse
    case malformedJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Gemini API key missing"
        case .http(let code, let msg): return "Gemini HTTP \(code): \(msg)"
        case .badResponse: return "Gemini returned an unexpected response shape"
        case .malformedJSON(let s): return "Gemini returned non-JSON content: \(s.prefix(120))"
        }
    }
}

actor GeminiClient {
    private let model = "gemini-3-flash-preview"
    private let endpoint = "https://generativelanguage.googleapis.com/v1beta/models"

    func evaluate(goal: String, jpegData: Data, apiKey: String) async throws -> GeminiVerdict {
        guard !apiKey.isEmpty else { throw GeminiError.missingAPIKey }

        var url = URLComponents(string: "\(endpoint)/\(model):generateContent")!
        url.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        let prompt = """
        You are a focus monitor for a user trying to stay on task. \
        The user's stated goal is: "\(goal)".
        Below is a screenshot of their screen. Your job is to actively flag distractions.

        DISTRACTION SURFACES — these are OFF-TASK by default, even if a search/title text \
        nominally mentions the goal. Watching/scrolling these is not the same as doing the work:
        - YouTube (any page: home, watch page, shorts, search results)
        - TikTok, Instagram, Instagram Reels, Facebook, Snapchat, Pinterest, Threads, BlueSky
        - Twitter / X (any tab)
        - Reddit (any subreddit, including "productivity"/"learnprogramming"-style ones)
        - Twitch, Netflix, Hulu, Disney+, HBO, Prime Video, any streaming video
        - News feeds and aggregators (CNN, NYT homepage, Hacker News front page, Google News)
        - Discord, Slack channels unrelated to the goal, iMessage/Messages, WhatsApp, Telegram
        - Online shopping (Amazon, eBay, etc.) unless the goal is shopping
        - Games, game launchers (Steam, Epic), game streaming
        - Email inbox triage (unless the goal is email)

        ON-TASK SURFACES — what real work looks like:
        - IDE / code editor open on project files (VS Code, Xcode, JetBrains, vim, etc.)
        - Terminal running builds/tests/scripts
        - Official documentation pages, API references, technical specs
        - Stack Overflow / GitHub issues / GitHub repos directly related to the goal
        - Design tools (Figma, Sketch) with project artifacts
        - A document/notes app where the user is writing about the goal
        - A blank/lock screen or app switcher (benefit of the doubt)

        Decision rules:
        - Treat the user as a procrastinator who will rationalize. \
          A YouTube video titled "How to learn \(goal)" is OFF-TASK — passive watching is procrastination.
        - If the screen shows a distraction surface, mark OFF-TASK and name the surface in the reason.
        - If the screen shows a productivity surface plausibly related to the goal, mark ON-TASK.
        - When the screen is mixed (e.g., IDE in background, YouTube in foreground), judge by what's foregrounded/visible most prominently.

        Output strict JSON only (no markdown, no fences):
        {"surface": "<short label of what's on screen, e.g. 'YouTube watch page', 'Xcode editing Swift', 'Reddit r/news'>", \
         "on_task": true|false, \
         "reason": "<one short sentence citing concrete on-screen evidence>"}
        """

        let payload: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt],
                    ["inline_data": [
                        "mime_type": "image/jpeg",
                        "data": jpegData.base64EncodedString()
                    ]]
                ]
            ]],
            "generationConfig": [
                "temperature": 0.1,
                "responseMimeType": "application/json"
            ]
        ]

        var req = URLRequest(url: url.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 30

        // Retry on transient capacity errors (429, 500, 502, 503, 504) with
        // exponential backoff + jitter. After max attempts, surface the error.
        let retryableCodes: Set<Int> = [429, 500, 502, 503, 504]
        let maxAttempts = 4
        var attempt = 0
        var data = Data()
        var http: HTTPURLResponse!

        while true {
            attempt += 1
            let (d, r) = try await URLSession.shared.data(for: req)
            guard let httpResp = r as? HTTPURLResponse else { throw GeminiError.badResponse }
            data = d
            http = httpResp

            if (200..<300).contains(httpResp.statusCode) { break }

            if retryableCodes.contains(httpResp.statusCode) && attempt < maxAttempts {
                // Backoff: 2s, 4s, 8s, with up to ±0.5s jitter.
                let base = pow(2.0, Double(attempt))
                let jitter = Double.random(in: -0.5...0.5)
                let delay = max(0.5, base + jitter)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }

            let body = String(data: d, encoding: .utf8) ?? ""
            throw GeminiError.http(httpResp.statusCode, body)
        }
        _ = http

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else {
            throw GeminiError.badResponse
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let inner = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        else {
            throw GeminiError.malformedJSON(trimmed)
        }

        let onTask = (inner["on_task"] as? Bool) ?? false
        let reason = (inner["reason"] as? String) ?? "(no reason given)"
        return GeminiVerdict(onTask: onTask, reason: reason)
    }
}
