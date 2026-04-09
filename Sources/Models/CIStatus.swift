import Foundation

struct CICheck: Codable {
    let name: String
    let state: String  // SUCCESS, FAILURE, PENDING, SKIPPED, etc.
    let link: String?
}

struct CIStatus {
    var checks: [CICheck]

    var overall: CIConclusion {
        if checks.isEmpty { return .pending }
        let meaningful = checks.filter { $0.state != "SKIPPED" }
        if meaningful.isEmpty { return .success }
        if meaningful.contains(where: { $0.state == "FAILURE" }) {
            return .failure
        }
        if meaningful.allSatisfy({ $0.state == "SUCCESS" }) {
            return .success
        }
        return .pending
    }

    var failedCheckNames: [String] {
        checks.filter { $0.state == "FAILURE" }.map(\.name)
    }

    var passedCount: Int {
        checks.filter { $0.state == "SUCCESS" }.count
    }

    var totalMeaningful: Int {
        checks.filter { $0.state != "SKIPPED" }.count
    }
}

enum CIConclusion {
    case success
    case failure
    case pending
}
