import Foundation

struct CICheck: Codable {
    let name: String
    let state: String
    let conclusion: String?
}

struct CIStatus {
    var checks: [CICheck]

    var overall: CIConclusion {
        if checks.isEmpty { return .pending }
        if checks.contains(where: { $0.conclusion == "failure" || $0.conclusion == "cancelled" }) {
            return .failure
        }
        if checks.allSatisfy({ $0.state == "completed" && $0.conclusion == "success" }) {
            return .success
        }
        return .pending
    }

    var failedCheckNames: [String] {
        checks.filter { $0.conclusion == "failure" }.map(\.name)
    }
}

enum CIConclusion {
    case success
    case failure
    case pending
}
