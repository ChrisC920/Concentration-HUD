import Foundation

enum FocusState: Equatable {
    case unknown
    case onTask
    case lookingAway
    case offTopic(reason: String)

    var isOnTask: Bool {
        if case .onTask = self { return true }
        return false
    }

    var displayLabel: String {
        switch self {
        case .unknown: return "Unknown"
        case .onTask: return "On task"
        case .lookingAway: return "Looking away"
        case .offTopic: return "Off topic"
        }
    }

    var reasonText: String? {
        if case .offTopic(let r) = self { return r }
        return nil
    }
}
