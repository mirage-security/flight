import Foundation

struct PRReview: Codable {
    let author: String
    let state: String  // APPROVED, CHANGES_REQUESTED, COMMENTED, PENDING, DISMISSED
}

struct PRStatus {
    var reviews: [PRReview]
    var reviewDecision: String?  // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED

    var approvedBy: [String] {
        reviews.filter { $0.state == "APPROVED" }.map(\.author)
    }

    var changesRequestedBy: [String] {
        reviews.filter { $0.state == "CHANGES_REQUESTED" }.map(\.author)
    }
}
