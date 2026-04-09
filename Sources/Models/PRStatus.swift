import Foundation

struct PRReview: Codable {
    let author: String
    let state: String  // APPROVED, CHANGES_REQUESTED, COMMENTED, PENDING, DISMISSED
}

struct PRComment {
    let author: String
    let body: String
    let path: String?
    let line: Int?

    /// First line of the comment, trimmed
    var summary: String {
        let first = body.components(separatedBy: "\n").first ?? body
        return first.trimmingCharacters(in: .whitespaces)
    }

    /// Whether this is an inline file comment vs a general PR comment
    var isInline: Bool { path != nil }
}

struct PRStatus {
    var reviews: [PRReview]
    var reviewDecision: String?  // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED
    var url: String?
    var comments: [PRComment] = []

    var approvedBy: [String] {
        reviews.filter { $0.state == "APPROVED" }.map(\.author)
    }

    var changesRequestedBy: [String] {
        reviews.filter { $0.state == "CHANGES_REQUESTED" }.map(\.author)
    }

    var inlineComments: [PRComment] {
        comments.filter(\.isInline)
    }
}
