import AppKit
import ZettyGhostty

/// Sheet for creating an agent account: a name, an identity color, and which
/// parts of the default setup to share into its new config directory.
///
/// Purely an editor, like `ProjectSettingsSheet`: it validates through
/// `AgentAccountSupport.make` and hands the result to `onCreate` — the
/// directory, the seeding and the sign-in all live in `AppDelegate`.
///
/// Two ways out: **Create & Sign In** (the default) opens a terminal on the new
/// account running its login command, and **Create** just records it. The
/// account is equally real either way — an unauthenticated one simply reports
/// "Not signed in yet" until you use **Sign In** from the Accounts list.
@MainActor
final class AddAccountSheet: NSObject {

    /// Keeps the active sheet alive until it ends.
    private static var active: AddAccountSheet?

    private let panel: NSWindow
    private let hostWindow: NSWindow
    private let existing: [AgentAccount]
    /// Every harness that can host accounts. More than one → a picker; exactly
    /// one → the sheet names it and the row is omitted.
    private let agents: [SpawnableAgent]
    private var agentID: String
    private let home: String
    /// `signIn` distinguishes the two buttons: create-and-authenticate versus
    /// create-only.
    private let onCreate: (AgentAccount, Set<String>, _ signIn: Bool) -> Void

    private let nameField = NSTextField(string: "")
    private var swatchButtons: [NSButton] = []
    private var selectedColorID: String?
    private let directoryLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private var seedChecks: [(item: AccountSeed.Item, button: NSButton)] = []
    private let agentPopup = NSPopUpButton()
    /// Rebuilt when the agent changes: each harness shares different files.
    private let shareStack = NSStackView()
    private let shareCaption = NSTextField(wrappingLabelWithString: "")

    static func present(
        existing: [AgentAccount],
        agentID: String,
        home: String = NSHomeDirectory(),
        on window: NSWindow,
        onCreate: @escaping (AgentAccount, Set<String>, Bool) -> Void
    ) {
        let sheet = AddAccountSheet(existing: existing, agentID: agentID, home: home,
                                    host: window, onCreate: onCreate)
        active = sheet
        window.beginSheet(sheet.panel)
    }

    private init(existing: [AgentAccount], agentID: String, home: String,
                 host: NSWindow,
                 onCreate: @escaping (AgentAccount, Set<String>, Bool) -> Void) {
        self.existing = existing
        self.agents = SpawnableAgent.accountCapable
        // Fall back to the first account-capable agent if the caller's default
        // isn't one, so the sheet can never open on an agent it can't create for.
        self.agentID = agents.contains { $0.id == agentID }
            ? agentID : (agents.first?.id ?? agentID)
        self.home = home
        self.hostWindow = host
        self.onCreate = onCreate

        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 10),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.appearance = ZTheme.current.appearance
        panel.backgroundColor = ZTheme.current.bg1Color
        panel.title = "Add Account"

        super.init()
        buildLayout()
        nameField.target = self
        nameField.action = #selector(nameChanged)
        refreshDirectoryLabel()
        let fit = panel.contentView?.fittingSize ?? .zero
        panel.setContentSize(fit == .zero ? NSSize(width: 420, height: 380) : fit)
        panel.initialFirstResponder = nameField
    }

    // MARK: Layout

    private func buildLayout() {
        let theme = ZTheme.current
        let title = NSTextField(labelWithString: "New account")
        title.font = ZTheme.chromeFont(size: 13)
        title.textColor = theme.accentColor

        let caption = NSTextField(wrappingLabelWithString:
            "A separate login with its own credentials and history. Your existing "
            + "login is untouched. Sign in now in a new terminal, or create the "
            + "account and sign in later.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = theme.fg3Color

        nameField.placeholderString = "Work"
        nameField.font = ZTheme.chromeFont(size: 13)

        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.spacing = 6
        let noneSwatch = makeSwatch(color: nil, tooltip: "Default")
        swatchButtons.append(noneSwatch)
        colorRow.addArrangedSubview(noneSwatch)
        for entry in ZTheme.projectPalette {
            let swatch = makeSwatch(color: ZTheme.projectColor(id: entry.id), tooltip: entry.id)
            swatchButtons.append(swatch)
            colorRow.addArrangedSubview(swatch)
        }
        refreshSwatchSelection()

        directoryLabel.font = ZTheme.chromeFont(size: 11)
        directoryLabel.textColor = theme.fg3Color

        errorLabel.font = ZTheme.chromeFont(size: 11)
        errorLabel.textColor = theme.redColor

        let shareTitle = NSTextField(labelWithString: "Share from your current setup")
        shareTitle.font = ZTheme.chromeFont(size: 12)
        shareTitle.textColor = theme.fgColor

        shareCaption.stringValue =
            "Shared items are symlinked, not copied — editing one changes both. "
            + "Config is copied so each account keeps its own. Logins, project "
            + "history and sessions are never shared."
        shareCaption.font = .systemFont(ofSize: 10)
        shareCaption.textColor = theme.fg3Color

        shareStack.orientation = .vertical
        shareStack.alignment = .leading
        shareStack.spacing = 4
        rebuildShareList()

        for agent in agents { agentPopup.addItem(withTitle: agent.displayName) }
        agentPopup.selectItem(at: agents.firstIndex { $0.id == agentID } ?? 0)
        agentPopup.target = self
        agentPopup.action = #selector(agentChanged)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let create = NSButton(title: "Create", target: self, action: #selector(createOnlyClicked))
        create.toolTip = "Set the account up now and sign in later from Settings \u{2192} Accounts."
        let createAndSignIn = NSButton(title: "Create & Sign In",
                                       target: self, action: #selector(createAndSignInClicked))
        createAndSignIn.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, create, createAndSignIn])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        var rows: [NSView] = [title, caption]
        if agents.count > 1 { rows.append(labelled("Agent", agentPopup)) }
        let root = NSStackView(views: rows + [
            labelled("Name", nameField),
            labelled("Color", colorRow),
            directoryLabel,
            shareTitle, shareCaption, shareStack,
            errorLabel, buttons,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        for view in [caption, shareCaption, errorLabel, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        }
        panel.contentView = root
    }

    private func labelled(_ text: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.font = ZTheme.chromeFont(size: 12)
        label.textColor = ZTheme.current.fg2Color
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        control.translatesAutoresizingMaskIntoConstraints = false
        if control is NSTextField {
            control.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        return row
    }

    private func makeSwatch(color: NSColor?, tooltip: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(swatchClicked(_:)))
        button.isBordered = false
        button.wantsLayer = true
        button.toolTip = tooltip
        button.layer?.cornerRadius = 9
        button.layer?.borderColor = ZTheme.current.fgColor.cgColor
        button.layer?.backgroundColor = color?.cgColor ?? ZTheme.current.bg3Color.cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 18).isActive = true
        button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return button
    }

    private func refreshSwatchSelection() {
        for (index, button) in swatchButtons.enumerated() {
            let id: String? = index == 0 ? nil : ZTheme.projectPalette[index - 1].id
            button.layer?.borderWidth = (id == selectedColorID) ? 2 : 0
        }
    }

    /// Shows where the account will live, updating as the name is typed — the
    /// directory is derived, never typed, so the path stays free of characters
    /// that a one-line ghostty directive can't carry.
    private func refreshDirectoryLabel() {
        let slug = AgentAccountSupport.slug(nameField.stringValue)
        guard !slug.isEmpty else {
            directoryLabel.stringValue = "Stored under ~/.zetty/accounts/"
            return
        }
        directoryLabel.stringValue = "Stored in ~/.zetty/accounts/\(slug)"
    }

    // MARK: Actions

    @objc private func nameChanged() { refreshDirectoryLabel() }

    /// Each harness shares a different set of files, so the checkbox list is
    /// rebuilt rather than re-labelled when the agent changes.
    @objc private func agentChanged() {
        let index = agentPopup.indexOfSelectedItem
        guard agents.indices.contains(index), agents[index].id != agentID else { return }
        agentID = agents[index].id
        rebuildShareList()
        errorLabel.stringValue = ""
        panel.contentView?.layout()
        let fit = panel.contentView?.fittingSize ?? .zero
        if fit != .zero { panel.setContentSize(fit) }
    }

    private func rebuildShareList() {
        for (_, button) in seedChecks { button.removeFromSuperview() }
        seedChecks.removeAll()

        let sourceRoot = AgentAccountSupport.agentHomeDirectory(agentID: agentID, home: home)
        for item in AccountSeed.shareable(forAgent: agentID) {
            let check = NSButton(checkboxWithTitle: item.displayName, target: nil, action: nil)
            check.font = ZTheme.chromeFont(size: 12)
            check.state = .on
            check.toolTip = item.detail
            // Required items aren't a choice; items with nothing to share are
            // greyed rather than hidden, so the list matches the documentation.
            let present = sourceRoot.map {
                FileManager.default.fileExists(
                    atPath: ($0 as NSString).appendingPathComponent(item.id))
            } ?? false
            if item.isRequired || !present {
                check.isEnabled = false
                check.state = present ? .on : .off
            }
            seedChecks.append((item, check))
            shareStack.addArrangedSubview(check)
        }
    }

    @objc private func swatchClicked(_ sender: NSButton) {
        guard let index = swatchButtons.firstIndex(of: sender) else { return }
        selectedColorID = index == 0 ? nil : ZTheme.projectPalette[index - 1].id
        refreshSwatchSelection()
    }

    @objc private func cancelClicked() {
        hostWindow.endSheet(panel)
        Self.active = nil
    }

    @objc private func createOnlyClicked() { create(signIn: false) }

    @objc private func createAndSignInClicked() { create(signIn: true) }

    private func create(signIn: Bool) {
        switch AgentAccountSupport.make(
            name: nameField.stringValue, directory: nil, agentID: agentID,
            colorID: selectedColorID, existing: existing, home: home
        ) {
        case .failure(let error):
            errorLabel.stringValue = message(for: error)
            panel.contentView?.layout()
        case .success(let account):
            let selections = Set(seedChecks.filter { $0.button.state == .on }.map(\.item.id))
            hostWindow.endSheet(panel)
            Self.active = nil
            onCreate(account, selections, signIn)
        }
    }

    private func message(for error: AgentAccountSupport.ValidationError) -> String {
        switch error {
        case .blankName:
            return "Give the account a name — letters or numbers."
        case .duplicateName:
            return "You already have an account with that name."
        case .duplicateDirectory:
            return "Another account already uses that directory."
        case .relativeDirectory:
            return "The directory must be an absolute path."
        case .directoryIsAgentHome:
            return "That's the default login's own directory — it's already the Default account."
        case .directoryIsHomeOrAncestor:
            return "That directory is your home folder or above it."
        case .directoryHasUnsafeCharacters:
            return "That path has characters Zetty can't pass to a terminal safely."
        }
    }
}
