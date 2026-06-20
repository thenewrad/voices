import Foundation

@MainActor
final class PushNotificationService: ObservableObject {
    static let shared = PushNotificationService()
    private init() {}

    /// Set when the user taps a push notification that should deep-link into
    /// the Activity center. Whichever feed view is on screen consumes (and
    /// clears) this value to open Activity with the right filter pre-selected.
    @Published var pendingActivityFilter: ActivityFilter?

    /// Inspects a notification payload's "type" field and routes the tap to
    /// the appropriate Activity filter tab.
    ///   - "direct_message" → Messages tab
    ///   - "reply" / "reply_to_reply" → Replies tab
    func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String else { return }
        switch type {
        case "direct_message":
            pendingActivityFilter = .messages
        case "reply", "reply_to_reply":
            pendingActivityFilter = .replies
        default:
            break
        }
    }

    func storeToken(_ tokenData: Data) async {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        do {
            let uid = try await SupabaseService.shared.client.auth.session.user.id
            struct TokenRow: Encodable {
                let user_id: UUID
                let token: String
                let platform: String
            }
            try await SupabaseService.shared.client
                .from("device_tokens")
                .upsert(
                    TokenRow(user_id: uid, token: token, platform: "apns"),
                    onConflict: "user_id"
                )
                .execute()
        } catch {
            // Non-fatal — realtime websocket still works without push tokens
            print("PushNotificationService.storeToken error: \(error)")
        }
    }
}
