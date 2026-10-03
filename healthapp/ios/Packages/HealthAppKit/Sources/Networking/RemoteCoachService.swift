import Foundation
import CoreModels

/// `CoachService` backed by `POST /v1/ai/coach`. The backend grounds answers in the user's own data and
/// returns citations; the app always shows a non-diagnostic disclaimer regardless of the response.
public struct RemoteCoachService: CoachService {
    private let api: APIClient
    public init(api: APIClient) { self.api = api }

    public func ask(_ message: String, conversationId: String) async throws -> CoachReply {
        var reply = try await api.send(try API.coach(CoachBody(conversationId: conversationId, message: message)))
        if reply.disclaimer == nil { reply.disclaimer = CoachCopy.disclaimer }
        return reply
    }
}
