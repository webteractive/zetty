import AppKit
import UserNotifications
import ZettyCore

/// The notifications Zetty's Tailscale node raises, each on entering its
/// state and never again while it holds: it needs a sign-in (clicking asks
/// Tailscale for a page and opens it, like Sign In…), a sign-in finished
/// (naming the account), it waits for the tailnet admin's approval, or it
/// failed.
/// Never a modal.
final class TailnetNotifier {
    static let category = "co.webteractive.zetty.tailnet"
    /// Marks the sign-in notification. It never carries the page itself: a
    /// notification can sit for days and the page expires.
    static let signInKey = "tailnetSignIn"

    private var last: TailnetState?

    /// A sign-in notification went out for the current sign-in.
    private var askedToSignIn = false
    private var signInWatch = TailnetSignInWatch()

    func note(_ state: TailnetState) {
        defer { last = state }
        // Says which account the sign-in landed on: one finished on a phone
        // (a QR code) may have picked a different account than meant.
        if signInWatch.note(state), case .running(let status) = state {
            let device = status.me?.hostName ?? "this Mac"
            post(title: "Signed in to Tailscale",
                 body: status.loginName.map { "This Mac joined as \($0) · \(device)." } ?? "This Mac joined as \(device).",
                 signIn: false)
            return
        }
        if case .needsLogin = state {} else { askedToSignIn = false }
        switch state {
        case .needsLogin(_?) where !askedToSignIn:
            // Only once Tailscale is ready to make a page.
            askedToSignIn = true
            post(title: "Sign in to Tailscale", body: "Zetty needs a Tailscale sign-in to reach your other Macs.",
                 signIn: true)
        case .needsApproval:
            if case .needsApproval? = last { return }
            post(title: "Waiting for approval",
                 body: "Your tailnet's admin needs to approve this Mac in Tailscale before your other Macs can connect.",
                 signIn: false)
        case .failed(let message):
            if case .failed(let old)? = last, old == message { return }
            post(title: "Other Macs stopped", body: message, signIn: false)
        default:
            return
        }
    }

    private func post(title: String, body: String, signIn: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.category
        if signIn { content.userInfo = [Self.signInKey: true] }
        let request = UNNotificationRequest(identifier: "\(Self.category).\(title)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
