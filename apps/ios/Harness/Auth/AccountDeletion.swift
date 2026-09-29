// In-app account deletion: the edge's `POST /auth/account/delete`, which the
// App Store requires of apps where an account can be made. The edge checks
// with CodeGraff first, wipes the person's agent rooms, then has CodeGraff
// delete the account and purges its own copy.

import Foundation

enum AccountDeletion: Equatable {
    case deleted
    /// The account is still there. `message` is what the person sees;
    /// `tokens` replace the stored pair, because the edge spends the
    /// CodeGraff refresh token on the way and a device that kept the old
    /// one would be signed out.
    case refused(message: String, tokens: AuthTokens?)

    init(status: Int, data: Data) {
        struct Body: Decodable {
            var deleted: Bool?
            var error: String?
            var message: String?
            var tokens: AuthTokens?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        if (200..<300).contains(status), body?.deleted == true {
            self = .deleted
            return
        }
        self = .refused(message: Self.message(status: status, error: body?.error, message: body?.message),
                        tokens: body?.tokens)
    }

    private static func message(status: Int, error: String?, message: String?) -> String {
        // A blocker the person has to clear (a paid plan), in CodeGraff's words.
        if status == 409 { return message ?? "Your account can't be deleted yet." }
        switch error {
        case "account_deletion_unavailable":
            return "Account deletion isn't available yet. Nothing was deleted."
        case "rooms_unavailable":
            return "Couldn't reach your agent rooms, so nothing was deleted. Try again in a moment."
        case "wrong_account":
            return "This sign-in belongs to a different account. Sign out, sign back in, then try again."
        case "codegraff_unavailable":
            return "Couldn't reach CodeGraff, so your account wasn't deleted. Try again in a moment."
        default:
            break
        }
        if status == 401 { return "Your sign-in has expired. Sign out, sign back in, then try again." }
        return "Couldn't delete your account (HTTP \(status)). Try again in a moment."
    }
}
