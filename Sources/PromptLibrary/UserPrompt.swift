import Foundation
import SwiftData

@Model
final class UserPrompt {
    @Attribute(.unique) var id: UUID
    var title: String
    var body: String
    var sampleInput: String?
    var sampleOutput: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        sampleInput: String? = nil,
        sampleOutput: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.sampleInput = sampleInput
        self.sampleOutput = sampleOutput
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var promptID: String { id.uuidString }
}
