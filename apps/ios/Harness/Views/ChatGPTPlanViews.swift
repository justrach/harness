// The small pieces OpenAI's guidelines ask for around ChatGPT plan usage (ChatGPTPlanViews.kt on Android): the
// "Using ChatGPT plan" line with a Manage usage link, the usage-limit card, the Settings card and the banner that
// invites someone who has not signed in with ChatGPT yet. Copy is pinned in apps/parity/ux-contract.json.

import SwiftUI

/// "Using ChatGPT plan · Manage usage": shown wherever requests run on the plan (near the composer, in Settings).
struct PlanUsageLine: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Using ChatGPT plan")
                .font(Theme.sans(12, weight: .medium))
                .foregroundStyle(Theme.textMuted)
            ManageUsageButton(font: Theme.sans(12, weight: .semibold))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan-usage-line")
    }
}

/// The link OpenAI wants beside every usage summary: it opens the plan's usage settings.
struct ManageUsageButton: View {
    @Environment(\.openURL) private var openURL
    var font: Font = Theme.sans(14, weight: .medium)

    var body: some View {
        Button("Manage usage") {
            if let url = URL(string: ChatGPTSignIn.manageUsageURL) { openURL(url) }
        }
        .font(font)
        .accessibilityIdentifier("chatgpt-manage-usage")
    }
}

/// A usage-limit error: Manage usage is the one action. Harness has no credits of its own, so there is no second one.
struct UsageLimitCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage limit reached")
                .font(Theme.sans(15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Review your plan or app limit in ChatGPT settings.")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            ManageUsageButton()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SheetStyle.cardFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hairline(0.06), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-limit-card")
    }
}

/// The dark pill that starts the sign-in. Text only: the approved logo asset is not bundled yet.
struct ContinueWithChatGPTButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Continue with ChatGPT")
                .font(Theme.sans(14, weight: .semibold))
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Theme.text, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("continue-with-chatgpt")
    }
}

/// Settings: what the option is, and either the button that starts it or the confirmation that it is on.
struct ChatGPTPlanCard: View {
    let connected: Bool
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use your ChatGPT plan")
                .font(Theme.sans(16, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Complete eligible AI requests in this app with usage included in your ChatGPT plan or credits balance.")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if connected { PlanUsageLine() } else { ContinueWithChatGPTButton(action: onContinue) }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatgpt-plan-card")
    }
}

/// Home: an invitation for someone who is signed in another way and has not connected ChatGPT.
struct ChatGPTPlanBanner: View {
    let onContinue: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("New")
                        .font(Theme.sans(11, weight: .semibold))
                        .foregroundStyle(Theme.bg)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.text, in: Capsule())
                    Text("Use your ChatGPT plan in this app")
                        .font(Theme.sans(14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ContinueWithChatGPTButton(action: onContinue)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SheetStyle.cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(hairline(0.06), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatgpt-plan-banner")
    }
}
