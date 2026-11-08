import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private let view: StatusBarView
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()

    private var isMenuOpen = false
    private var needsMenuRebuild = false

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: 73)
        self.view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 73, height: 22))
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        view.onOpenMenu = { [weak self] in self?.openMenu() }
        view.toolTip = "DeepSeek usage"
        statusItem.view = view
        statusItem.menu = nil

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the property is stored.
                DispatchQueue.main.async { self?.render() }
            }
            .store(in: &cancellables)

        render()
    }

    // MARK: Rendering

    private func render() {
        let snapshot = model.snapshot
        let primary: String
        let secondary: String
        let accent: NSColor

        if model.isSigningIn {
            primary = "Signing in…"
            secondary = "Check browser"
            accent = .systemBlue
        } else if let balance = snapshot.balance {
            primary = Fmt.money(balance.total, currency: balance.currency)
            if let usage = snapshot.usage, let cost = usage.cost {
                secondary = "\(Fmt.money(cost, currency: usage.currency)) today"
            } else {
                secondary = "today —"
            }
            if snapshot.needsReauth {
                accent = .systemOrange
            } else if balance.total <= 0 {
                accent = .systemRed
            } else if balance.total < 5 {
                accent = .systemOrange
            } else {
                accent = .systemGreen
            }
        } else if !model.hasAnyCredential {
            if model.harnessAvailable {
                primary = "Harness"
                secondary = "sign in"
            } else {
                primary = "Sign in"
                secondary = "DeepSeek"
            }
            accent = .systemGray
        } else if model.isLoading {
            primary = "Loading…"
            secondary = "DeepSeek"
            accent = .systemGray
        } else if snapshot.needsReauth {
            primary = "Re-auth"
            secondary = "Open menu"
            accent = .systemOrange
        } else {
            primary = "—"
            secondary = "Unavailable"
            accent = .systemRed
        }

        view.update(primary: primary, secondary: secondary, accent: accent)
        view.toolTip = tooltip(primary: primary, secondary: secondary, snapshot: snapshot)
        rebuildMenu()
    }

    private func tooltip(primary: String, secondary: String, snapshot: AppSnapshot) -> String {
        if let error = snapshot.error, !error.isEmpty {
            return "DeepSeek — \(primary) · \(secondary)\n\(error)"
        }
        return "DeepSeek — \(primary) · \(secondary)"
    }

    private func rebuildMenu() {
        guard !isMenuOpen else {
            needsMenuRebuild = true
            return
        }
        needsMenuRebuild = false

        menu.removeAllItems()

        if let name = model.accountName, !name.isEmpty {
            addDisabled(name, secondary: true)
        } else if model.hasOAuthToken {
            addDisabled("DeepSeek account", secondary: true)
        }

        guard model.hasAnyCredential else {
            addSetupMenu()
            addFooter()
            return
        }

        addBalanceSection()
        menu.addItem(.separator())
        addUsageSection()
        addErrorSection()
        addUpdatedRow()
        addFooter()
    }

    private func addSetupMenu() {
        addAction(
            "Sign in with DeepSeek…",
            action: #selector(signInAction),
            symbol: "person.crop.circle.badge.checkmark")
        addAction(
            "Enter API Key…",
            action: #selector(settingsAction),
            symbol: "key")
    }

    private func addBalanceSection() {
        let snapshot = model.snapshot
        if let balance = snapshot.balance {
            addBold("Balance   \(Fmt.money(balance.total, currency: balance.currency))")
            addSecondary(
                "Paid \(Fmt.money(balance.toppedUp, currency: balance.currency)) · Granted \(Fmt.money(balance.granted, currency: balance.currency))")
            for extra in balance.extras {
                var line = "Also \(Fmt.money(extra.total, currency: extra.currency))"
                if extra.granted > 0 && extra.toppedUp == 0 {
                    line += " bonus"
                }
                addSecondary(line)
            }
            if !balance.isAvailable {
                addWarning("Balance unavailable for API calls")
            }
        } else {
            addSecondary("Balance unavailable")
            if !model.hasAPIKey {
                addAction("Add API key…", action: #selector(settingsAction), symbol: "key")
            }
        }
    }

    private func addUsageSection() {
        let snapshot = model.snapshot
        if let usage = snapshot.usage {
            let todayCost = usage.cost.map { Fmt.money($0, currency: usage.currency) } ?? "—"
            addBold("Today   \(todayCost)")
            var details: [String] = []
            details.append("\(Fmt.tokens(usage.totalTokens)) tokens")
            details.append("\(usage.requests) requests")
            addSecondary(details.joined(separator: " · "))

            if let rate = usage.cacheHitRate {
                addSecondary("Cache hit \(rate)%")
            }

            addSecondary(
                "\(usage.period.label)   \(Fmt.tokens(usage.periodTokens)) tokens")
            if usage.approximate {
                addSecondary("Monthly endpoint (approximate)", color: .systemOrange)
            }

            addSevenDaySubmenu(usage: usage)
        } else {
            addSecondary("Today   —")
            if !model.hasAccountToken {
                addAction(
                    "Sign in for usage…",
                    action: #selector(signInAction),
                    symbol: "person.crop.circle.badge.checkmark")
            } else if snapshot.needsReauth {
                addAction(
                    model.tokenSource == .harness
                        ? "Session expired — re-sign in from DeepSeek Harness…"
                        : "Session expired — sign in again…",
                    action: #selector(signInAction),
                    symbol: "exclamationmark.arrow.trianglehead.counterclockwise")
            }
        }
    }

    private func addSevenDaySubmenu(usage: UsageSnapshot) {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for day in usage.daily.reversed() {
            // Tokens are currency-neutral; spend is shown for today above because an
            // account can have cost buckets in more than one currency.
            let title = "\(Fmt.dayLabel(day.date))   \(Fmt.tokens(day.tokens)) tokens   \(day.requests) req"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        if submenu.items.isEmpty {
            let item = NSMenuItem(title: "No usage data", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Last 7 days", action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func addErrorSection() {
        let snapshot = model.snapshot
        guard let error = snapshot.error, !error.isEmpty else { return }
        menu.addItem(.separator())
        let lines = error.components(separatedBy: "\n").filter { !$0.isEmpty }
        for line in lines.prefix(3) {
            addWarning(line)
        }
        if lines.count > 3 {
            addSecondary("…")
        }
        if snapshot.needsReauth {
            if model.tokenSource == .harness {
                addSecondary("Harness file: re-sign in from DeepSeek Harness (DSH) to renew.")
            }
            addAction(
                "Sign in again…",
                action: #selector(signInAction),
                symbol: "person.crop.circle.badge.checkmark")
        }
    }

    private func addUpdatedRow() {
        guard let updated = model.snapshot.updatedAt else { return }
        var text = "Updated \(Fmt.time(updated))"
        if model.snapshot.isStale {
            text += " · stale"
        }
        addSecondary(text)
    }

    private func addFooter() {
        menu.addItem(.separator())
        addAction("Refresh", action: #selector(refreshAction), key: "r", symbol: "arrow.clockwise")
        addAction("Settings…", action: #selector(settingsAction), key: ",", symbol: "gearshape")
        addAction("Open DeepSeek Usage", action: #selector(usagePageAction), symbol: "safari")
        menu.addItem(.separator())
        addAction("Quit", action: #selector(quitAction), key: "q", symbol: "power")
    }

    // MARK: Menu item helpers

    private func addBold(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
        menu.addItem(item)
    }

    private func addSecondary(_ title: String, color: NSColor = .secondaryLabelColor) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: color,
            ])
        menu.addItem(item)
    }

    private func addDisabled(_ title: String, secondary: Bool) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if secondary {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ])
        }
        menu.addItem(item)
    }

    private func addWarning(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = title
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.systemRed,
            ])
        menu.addItem(item)
    }

    private func addAction(
        _ title: String,
        action: Selector,
        key: String = "",
        symbol: String? = nil
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        menu.addItem(item)
    }

    // MARK: Menu lifecycle

    private func openMenu() {
        guard !menu.items.isEmpty else { return }
        // The custom status view is not flipped, so y = 0 is its bottom edge.
        // Anchor the menu just below the menu bar instead of above the item.
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: -4),
            in: view)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        if needsMenuRebuild {
            render()
        }
    }

    // MARK: Actions

    @objc private func signInAction() {
        model.signIn()
    }

    @objc private func refreshAction() {
        model.refreshNow()
    }

    @objc private func settingsAction() {
        openSettings()
    }

    @objc private func usagePageAction() {
        model.openUsagePage()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
