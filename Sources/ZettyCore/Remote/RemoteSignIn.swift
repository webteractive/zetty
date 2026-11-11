import Foundation

/// What `zetty remote sign-in` gets back from the app: a Tailscale sign-in
/// page to open on any device (with its QR code), or why there's nothing to
/// sign in. Off, still connecting and failed answer `.error` instead.
public struct RemoteSignInReport: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case needsSignIn = "needs-sign-in"
        case signedIn = "signed-in"
        case needsApproval = "needs-approval"
    }

    public let state: State
    /// The page Tailscale just made (needs-sign-in only). It signs this
    /// Zetty in to whoever opens it.
    public let url: String?
    /// The account and device, when signed in.
    public let account: String?
    public let device: String?
    /// The page's QR code, one string per row, "1" dark and "0" light. The
    /// app draws it (ZettyCore has no QR encoder); the CLI prints it.
    public let qr: [String]?

    public init(state: State, url: String? = nil, account: String? = nil, device: String? = nil,
                qr: [String]? = nil) {
        self.state = state
        self.url = url
        self.account = account
        self.device = device
        self.qr = qr
    }

    /// `qr` as rows of dark (true) and light modules.
    public var modules: [[Bool]]? {
        qr.map { rows in rows.map { $0.map { $0 == "1" } } }
    }

    /// The report without its code, for `--json`.
    public var withoutCode: RemoteSignInReport {
        RemoteSignInReport(state: state, url: url, account: account, device: device)
    }
}

/// A QR code drawn in a terminal: two rows of modules per line with half
/// blocks, black on bright white whatever the terminal's own colors (a
/// light-on-dark code scans badly), inside a light border.
public enum QRText {
    private static let colors = "\u{1B}[30;107m"
    private static let reset = "\u{1B}[0m"

    public static func lines(_ modules: [[Bool]], quiet: Int = 2) -> [String] {
        guard let width = modules.map(\.count).max(), width > 0 else { return [] }
        let blank = [Bool](repeating: false, count: width + quiet * 2)
        let pad = [Bool](repeating: false, count: quiet)
        var rows = [[Bool]](repeating: blank, count: quiet)
        for row in modules {
            rows.append(pad + row + [Bool](repeating: false, count: width - row.count) + pad)
        }
        rows += [[Bool]](repeating: blank, count: quiet)

        var lines: [String] = []
        for top in stride(from: 0, to: rows.count, by: 2) {
            let upper = rows[top]
            let lower = top + 1 < rows.count ? rows[top + 1] : blank
            let cells = zip(upper, lower).map { pair -> Character in
                switch pair {
                case (true, true): "█"
                case (true, false): "▀"
                case (false, true): "▄"
                case (false, false): " "
                }
            }
            lines.append(colors + String(cells) + reset)
        }
        return lines
    }
}
