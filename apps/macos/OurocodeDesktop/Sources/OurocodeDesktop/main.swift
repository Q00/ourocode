import AppKit

private final class MainToolbarController: NSObject {
    private weak var split: NSSplitViewController?
    private weak var rail: SessionRailViewController?
    private weak var terminal: TerminalHostViewController?
    private var splitResizeObserver: NSObjectProtocol?

    init(split: NSSplitViewController, rail: SessionRailViewController, terminal: TerminalHostViewController) {
        self.split = split
        self.rail = rail
        self.terminal = terminal
        super.init()
        splitResizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: split.splitView,
            queue: .main
        ) { [weak self] _ in
            self?.syncSessionsVisibility()
        }
    }

    deinit {
        if let splitResizeObserver {
            NotificationCenter.default.removeObserver(splitResizeObserver)
        }
    }

    @objc func toggleSessions(_ sender: Any?) {
        guard let item = split?.splitViewItems.first else { return }
        item.isCollapsed.toggle()
        syncSessionsVisibility()
        if item.isCollapsed {
            terminal?.focusTerminal(nil)
        } else {
            rail?.focusBrowser(nil)
        }
    }

    @objc func showSessionsAndFocus(_ sender: Any?) {
        guard let item = split?.splitViewItems.first else { return }
        item.isCollapsed = false
        syncSessionsVisibility()
        rail?.focusBrowser(nil)
    }

    private func syncSessionsVisibility() {
        guard let item = split?.splitViewItems.first else { return }
        let visible = !item.isCollapsed
        rail?.setSidebarExpanded(visible)
        terminal?.setSourcesVisible(visible)
    }
}

private final class MainWindowContext {
    let window: NSWindow
    let terminal: TerminalHostViewController
    let rail: SessionRailViewController
    let toolbar: MainToolbarController
    let settings: TerminalSettingsWindowController
    var commandPalette: CommandPaletteCoordinator?

    init(
        window: NSWindow,
        terminal: TerminalHostViewController,
        rail: SessionRailViewController,
        toolbar: MainToolbarController,
        settings: TerminalSettingsWindowController
    ) {
        self.window = window
        self.terminal = terminal
        self.rail = rail
        self.toolbar = toolbar
        self.settings = settings
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, CommandProvider {
    private var window: NSWindow?
    private var terminalController: TerminalHostViewController?
    private var railController: SessionRailViewController?
    private var toolbarController: MainToolbarController?
    private var settingsController: TerminalSettingsWindowController?
    private var displayOptionsObserver: NSObjectProtocol?
    private var applicationKeyMonitor: Any?
    private var commandPalette: CommandPaletteCoordinator?
    private var windowContexts: [ObjectIdentifier: MainWindowContext] = [:]
    private let sharedOuroborosService = SharedOuroborosServiceRuntime.shared
    let commandProviderID = CommandProviderID(rawValue: "application")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        BundledTerminalFont.register()
        let context = makeMainWindowContext()
        installMainMenu(terminal: context.terminal, rail: context.rail, toolbar: context.toolbar)
        activate(context)
        installApplicationKeyMonitor()
        context.window.center()
        context.window.makeKeyAndOrderFront(nil)
        applyAccessibilityPreferences()
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAccessibilityPreferences()
        }

        NSApp.activate(ignoringOtherApps: true)
        startSharedOuroborosIfConfigured()
        let defaults = UserDefaults.standard
        if PermissionOnboardingPolicy.shouldPresent(
            arguments: ProcessInfo.processInfo.arguments,
            bundlePath: Bundle.main.bundlePath,
            alreadyPresented: defaults.bool(forKey: PermissionOnboardingPolicy.presentedKey)
        ) {
            defaults.set(true, forKey: PermissionOnboardingPolicy.presentedKey)
            DispatchQueue.main.async { [weak self] in
                self?.showSettings(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowContexts.values.forEach { $0.rail.stopSources() }
        if let applicationKeyMonitor {
            NSEvent.removeMonitor(applicationKeyMonitor)
            self.applicationKeyMonitor = nil
        }
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        settingsController?.present()
    }

    @objc func showCommandPalette(_ sender: Any?) {
        commandPalette?.toggle(relativeTo: window)
    }

    @objc func focusFocusedAgentComposer(_ sender: Any?) {
        toolbarController?.showSessionsAndFocus(sender)
        railController?.focusSteeringComposer(sender)
    }

    @objc func newWindow(_ sender: Any?) {
        let previousWindow = window
        let context = makeMainWindowContext()
        activate(context)
        if let previousWindow {
            let nextTopLeft = previousWindow.cascadeTopLeft(from: previousWindow.frame.origin)
            context.window.setFrameTopLeftPoint(nextTopLeft)
        } else {
            context.window.center()
        }
        context.window.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let context = windowContexts[ObjectIdentifier(window)] else { return }
        activate(context)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              let context = windowContexts.removeValue(
                forKey: ObjectIdentifier(closingWindow)
              ) else { return }
        context.rail.stopSources()
        if window === closingWindow, let replacement = windowContexts.values.first {
            activate(replacement)
        }
    }

    func commandSnapshot(limit: Int) -> [CommandDescriptor] {
        let provider = commandProviderID
        return Array([
            CommandDescriptor(
                id: CommandID(provider: provider, local: "new-window"),
                title: "New Window",
                keywords: ["window", "terminal", "shell"],
                section: .actions,
                shortcut: "⌘N",
                symbolName: "macwindow.badge.plus",
                rankHint: 95
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "settings"),
                title: "Open Settings",
                keywords: ["preferences", "font", "bell"],
                section: .actions,
                shortcut: "⌘,",
                symbolName: "gearshape",
                rankHint: 85
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "connections"),
                title: "Show Connections",
                subtitle: "Browse MCP v2 and agent sessions",
                keywords: ["ouroboros", "sessions", "mcp", "agents"],
                section: .connections,
                shortcut: "⌃⌘S",
                symbolName: "sidebar.left",
                rankHint: 75
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "focus-terminal"),
                title: "Focus Terminal",
                keywords: ["shell", "zsh"],
                section: .actions,
                shortcut: "⌥⌘2",
                symbolName: "terminal",
                rankHint: 65
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "text-bigger"),
                title: "Make Terminal Text Bigger",
                keywords: ["zoom", "font", "text", "increase", "larger", "bigger"],
                section: .actions,
                shortcut: "⌘+",
                symbolName: "textformat.size.larger",
                rankHint: 20
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "text-smaller"),
                title: "Make Terminal Text Smaller",
                keywords: ["zoom", "font", "text", "decrease", "smaller"],
                section: .actions,
                shortcut: "⌘−",
                symbolName: "textformat.size.smaller",
                rankHint: 20
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "actual-size"),
                title: "Reset Terminal Text Size",
                keywords: ["zoom", "font", "text", "default", "actual size", "reset"],
                section: .actions,
                shortcut: "⌘0",
                symbolName: "textformat.size",
                rankHint: 15
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "toggle-full-screen"),
                title: "Toggle Full Screen",
                keywords: ["window", "fullscreen", "focus"],
                section: .actions,
                shortcut: "⌃⌘F",
                symbolName: "arrow.up.left.and.arrow.down.right",
                rankHint: 15
            ),
        ].prefix(max(0, limit)))
    }

    func perform(commandID: CommandID) -> CommandExecutionResult {
        guard commandID.provider == commandProviderID else {
            return .unavailable("The application command is no longer available.")
        }
        switch commandID.local {
        case "new-window": newWindow(nil)
        case "settings": showSettings(nil)
        case "connections": toolbarController?.showSessionsAndFocus(nil)
        case "focus-terminal": terminalController?.focusTerminal(nil)
        case "text-bigger": dispatchTypography(.increase)
        case "text-smaller": dispatchTypography(.decrease)
        case "actual-size": dispatchTypography(.reset)
        case "toggle-full-screen": window?.toggleFullScreen(nil)
        default: return .unavailable("That application command no longer exists.")
        }
        return .executed
    }

    @objc func closeActiveContext(_ sender: Any?) {
        guard let keyWindow = NSApp.keyWindow else { return }
        switch closeDestination(for: keyWindow) {
        case .terminalTab:
            terminalController?.closeTab(sender)
        case .keyWindow:
            keyWindow.performClose(sender)
        case .unavailable:
            NSSound.beep()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(increaseApplicationTextSize(_:)):
            return terminalController?.isTypographyActionEnabled(.increase) == true
        case #selector(decreaseApplicationTextSize(_:)):
            return terminalController?.isTypographyActionEnabled(.decrease) == true
        case #selector(resetApplicationTextSize(_:)):
            return terminalController?.isTypographyActionEnabled(.reset) == true
        default: break
        }
        guard menuItem.action == #selector(closeActiveContext(_:)),
              let keyWindow = NSApp.keyWindow else { return true }
        switch closeDestination(for: keyWindow) {
        case .terminalTab:
            menuItem.title = "Close Tab"
            return true
        case .keyWindow:
            menuItem.title = "Close Window"
            return true
        case .unavailable:
            menuItem.title = keyWindow === window ? "Close Tab" : "Close Window"
            return false
        }
    }

    private func closeDestination(for keyWindow: NSWindow) -> MacApplicationCommandRouting.CloseDestination {
        let terminalContext = windowContexts[ObjectIdentifier(keyWindow)]
        return MacApplicationCommandRouting.closeDestination(
            hasKeyWindow: true,
            keyWindowIsTerminalWindow: terminalContext != nil,
            keyWindowIsClosable: keyWindow.styleMask.contains(.closable),
            terminalCanCloseTab: terminalContext?.terminal.canCloseSelectedTab == true
        )
    }

    private func makeMainWindowContext() -> MainWindowContext {
        let split = NSSplitViewController()
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin

        let terminal = TerminalHostViewController()
        let rail = SessionRailViewController()
        let settings = TerminalSettingsWindowController(
            terminal: terminal,
            sharedOuroborosService: sharedOuroborosService
        )
        let railItem = NSSplitViewItem(viewController: rail)
        // Sources is a navigator, not an IDE inspector. Keep enough width for
        // MCP names while returning the reading plane to the terminal.
        railItem.minimumThickness = SessionDetailSurfacePolicy.browsingRailWidth
        railItem.maximumThickness = 360
        railItem.canCollapse = true
        railItem.holdingPriority = .defaultHigh

        let terminalItem = NSSplitViewItem(viewController: terminal)
        terminalItem.minimumThickness = 520
        split.addSplitViewItem(railItem)
        split.addSplitViewItem(terminalItem)
        split.splitView.setPosition(SessionDetailSurfacePolicy.browsingRailWidth, ofDividerAt: 0)
        railItem.isCollapsed = false
        rail.setSidebarExpanded(true)
        terminal.setSourcesVisible(true)

        let toolbar = MainToolbarController(split: split, rail: rail, terminal: terminal)
        terminal.onToggleSources = { [weak toolbar] in toolbar?.toggleSessions(nil) }
        terminal.onOpenSettings = { [weak settings] in settings?.present() }
        terminal.onSessionMessageCapabilityStateChange = { [weak rail] state in
            rail?.updateSessionMessageCapability(state)
        }
        terminal.onFocusedSessionPaneChange = { [weak rail] focus in
            rail?.focusSessionPane(focus)
        }
        terminal.onLiveTerminalSessionsChange = { [weak rail] sessions in
            rail?.updateLiveTerminalSessions(sessions)
        }
        rail.onRequestActivateLiveTerminal = { [weak terminal] id in
            terminal?.activateLiveTerminalSession(id) == true
        }
        rail.onRequestOpen = { [weak toolbar] in toolbar?.showSessionsAndFocus(nil) }
        rail.onSessionTerminalBindingsChange = { [weak terminal] bindings in
            terminal?.applySessionBindings(bindings)
        }
        rail.onRequestActivateTerminal = { [weak terminal] identity, bindings, requestIsCurrent, completion in
            guard let terminal else {
                completion(.unavailable(.noCurrentBrokerGeneration))
                return
            }
            terminal.activateSessionLeaf(
                identity,
                bindings: bindings,
                requestIsCurrent: requestIsCurrent,
                completion: completion
            )
        }
        rail.onRequestPresentSessionWorkspace = { [weak terminal] detail in
            terminal?.presentSessionWorkspace(detail)
        }
        rail.onRequestDismissSessionWorkspace = { [weak terminal] detail in
            terminal?.dismissSessionWorkspace(detail)
        }

        let mainWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        mainWindow.title = "Ourocode"
        mainWindow.titleVisibility = .hidden
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.toolbarStyle = .unifiedCompact
        mainWindow.setAccessibilityIdentifier("OurocodeMainWindow")
        mainWindow.setAccessibilityTitle("Ourocode")
        mainWindow.setAccessibilityHelp(
            "A terminal work area with MCP connections. Command-N opens another terminal window. Command-1 through Command-9 switch terminal tabs. Command-plus and Command-minus resize terminal text; Command-zero restores the default. Use the sidebar button to show or hide Connections."
        )
        mainWindow.backgroundColor = OuroTheme.canvas
        mainWindow.isMovableByWindowBackground = true
        mainWindow.minSize = NSSize(width: 840, height: 560)
        mainWindow.tabbingMode = .disallowed
        mainWindow.contentViewController = split
        mainWindow.delegate = self

        let context = MainWindowContext(
            window: mainWindow,
            terminal: terminal,
            rail: rail,
            toolbar: toolbar,
            settings: settings
        )
        do {
            let registry = try CommandRegistry(providers: [self, terminal, rail])
            let palette = CommandPaletteCoordinator(registry: registry)
            context.commandPalette = palette
            terminal.onOpenCommandPalette = { [weak palette, weak mainWindow] in
                palette?.toggle(relativeTo: mainWindow)
            }
        } catch {
            assertionFailure("Command registry construction failed: \(error)")
        }
        windowContexts[ObjectIdentifier(mainWindow)] = context
        return context
    }

    private func activate(_ context: MainWindowContext) {
        window = context.window
        terminalController = context.terminal
        railController = context.rail
        toolbarController = context.toolbar
        settingsController = context.settings
        commandPalette = context.commandPalette
        retargetMainMenu(to: context)
    }

    /// The app has one native main menu, while every terminal window owns an
    /// independent TerminalHost and broker lease. Retarget only controller-
    /// owned items when key-window authority changes; responder-chain Edit and
    /// Window commands remain untouched.
    private func retargetMainMenu(to context: MainWindowContext) {
        guard let mainMenu = NSApp.mainMenu else { return }
        func retarget(_ menu: NSMenu) {
            for item in menu.items {
                if item.target is TerminalHostViewController {
                    item.target = context.terminal
                } else if item.target is MainToolbarController {
                    item.target = context.toolbar
                }
                if let submenu = item.submenu { retarget(submenu) }
            }
        }
        retarget(mainMenu)
    }

    private func installApplicationKeyMonitor() {
        guard applicationKeyMonitor == nil else { return }
        applicationKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            let eventWindow = event.window ?? NSApp.keyWindow
            let eventContext = eventWindow.flatMap {
                self.windowContexts[ObjectIdentifier($0)]
            }
            let terminal: TerminalHostViewController?
            switch MacApplicationCommandRouting.typographyTarget(
                hasEventWindowContext: eventContext != nil,
                hasActiveWindowContext: self.terminalController != nil
            ) {
            case .eventWindow: terminal = eventContext?.terminal
            case .activeWindow: terminal = self.terminalController
            case .unavailable: terminal = nil
            }
            guard let terminal else { return event }
            if let action = MacApplicationCommandRouting.typographyAction(
                    applicationIsActive: NSApp.isActive,
                    hasApplicationWindow: NSApp.keyWindow != nil,
                    hasEligibleTerminal: terminal.hasEligibleTerminalForApplicationTypography,
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers
                  ) {
                self.dispatchTypography(action, preferredTerminal: terminal)
                return nil
            }
            guard eventContext != nil,
                  let action = MacApplicationCommandRouting.terminalAction(
                    applicationIsActive: NSApp.isActive,
                    hasApplicationWindow: true,
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers
                  ) else { return event }
            switch action {
            case .clearScreen: terminal.clearTerminalScreen(nil)
            case .scrollToTop: terminal.scrollTerminalToTop(nil)
            case .scrollToBottom: terminal.scrollTerminalToBottom(nil)
            }
            return nil
        }
    }

    @objc private func increaseApplicationTextSize(_ sender: Any?) {
        dispatchTypography(.increase)
    }

    @objc private func decreaseApplicationTextSize(_ sender: Any?) {
        dispatchTypography(.decrease)
    }

    @objc private func resetApplicationTextSize(_ sender: Any?) {
        dispatchTypography(.reset)
    }

    @discardableResult
    private func dispatchTypography(
        _ action: TerminalTypographyShortcut,
        preferredTerminal: TerminalHostViewController? = nil
    ) -> Bool {
        guard let terminal = preferredTerminal ?? terminalController,
              terminal.hasEligibleTerminalForApplicationTypography else { return false }
        terminal.performTypographyShortcut(action)
        return true
    }

    private func applyAccessibilityPreferences() {
        guard let window else { return }
        window.titlebarAppearsTransparent = !OuroTheme.accessibility.reduceTransparency
        window.backgroundColor = OuroTheme.canvas
        window.contentView?.needsDisplay = true
    }

    private func startSharedOuroborosIfConfigured() {
        guard case .sharedDefault(
            let autoStart,
            let ouroborosExecutable,
            let uvxExecutable
        ) = LaunchConfiguration.ouroborosSelection,
        autoStart,
        let ouroborosExecutable else { return }

        SharedCUAServiceRuntime.start { [weak self] result in
            guard case .success = result else { return }
            let bridgeData = SharedOuroborosBridgeConfig.data
            let support = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Ourocode", isDirectory: true)
            let bridgeConfig = support.appendingPathComponent(SharedOuroborosBridgeConfig.fileName)
            do {
                try FileManager.default.createDirectory(
                    at: support,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try bridgeData.write(to: bridgeConfig, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: bridgeConfig.path
                )
            } catch { return }
            let restart = Process()
            restart.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            restart.arguments = [
                "kickstart", "-k",
                "gui/\(getuid())/\(SharedOuroborosResolver.sharedLaunchdLabel)",
            ]
            restart.standardOutput = FileHandle.nullDevice
            restart.standardError = FileHandle.nullDevice
            if (try? restart.run()) != nil { restart.waitUntilExit() }
            self?.sharedOuroborosService.start(
                ouroborosPath: ouroborosExecutable.path,
                uvxPath: uvxExecutable?.path,
                bridgeConfigPath: bridgeConfig.path,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            ) { [weak self] result in
                guard case .failure = result else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self?.sharedOuroborosService.retry()
                }
            }
        }
    }

    private func installMainMenu(
        terminal: TerminalHostViewController,
        rail: SessionRailViewController,
        toolbar: MainToolbarController
    ) {
        let menu = NSMenu()

        let appItem = NSMenuItem(title: "Ourocode", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Ourocode", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(
            withTitle: MacCommandAccessibility.settings.title,
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: MacCommandAccessibility.settings.keyEquivalent
        )
        MacCommandAccessibility.apply(MacCommandAccessibility.settings, to: settings)
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Ourocode", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Ourocode", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let shellItem = NSMenuItem(title: "Shell", action: nil, keyEquivalent: "")
        let shellMenu = NSMenu(title: "Shell")
        let palette = shellMenu.addItem(
            withTitle: "Command Palette…",
            action: #selector(AppDelegate.showCommandPalette(_:)),
            keyEquivalent: "p"
        )
        palette.target = self
        shellMenu.addItem(.separator())
        let newWindow = shellMenu.addItem(
            withTitle: "New Window",
            action: #selector(AppDelegate.newWindow(_:)),
            keyEquivalent: NativeTerminalShortcutPolicy.newWindowKeyEquivalent
        )
        newWindow.target = self
        let newTab = shellMenu.addItem(withTitle: "New Tab", action: #selector(TerminalHostViewController.addTab(_:)), keyEquivalent: "t")
        newTab.target = terminal
        let splitRight = shellMenu.addItem(
            withTitle: "Split Right",
            action: #selector(TerminalHostViewController.splitPaneRight(_:)),
            keyEquivalent: "d"
        )
        splitRight.target = terminal
        let splitDown = shellMenu.addItem(
            withTitle: "Split Down",
            action: #selector(TerminalHostViewController.splitPaneDown(_:)),
            keyEquivalent: "d"
        )
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        splitDown.target = terminal
        let closePane = shellMenu.addItem(
            withTitle: "Close Focused Pane",
            action: #selector(TerminalHostViewController.closeFocusedPane(_:)),
            keyEquivalent: "w"
        )
        closePane.keyEquivalentModifierMask = [.command, .option]
        closePane.target = terminal
        let equalizePanes = shellMenu.addItem(
            withTitle: "Equalize Panes",
            action: #selector(TerminalHostViewController.equalizePanes(_:)),
            keyEquivalent: "e"
        )
        equalizePanes.keyEquivalentModifierMask = [.command, .shift, .control]
        equalizePanes.target = terminal
        let maximizePane = shellMenu.addItem(
            withTitle: "Maximize / Restore Focused Pane",
            action: #selector(TerminalHostViewController.toggleMaximizeFocusedPane(_:)),
            keyEquivalent: "\r"
        )
        maximizePane.keyEquivalentModifierMask = [.command, .shift]
        maximizePane.target = terminal
        shellMenu.addItem(.separator())
        let focusLeft = shellMenu.addItem(withTitle: "Focus Pane Left", action: #selector(TerminalHostViewController.focusPaneLeft(_:)), keyEquivalent: "")
        focusLeft.keyEquivalentModifierMask = [.command, .option]
        focusLeft.keyEquivalent = "\u{F702}"
        focusLeft.target = terminal
        let focusRight = shellMenu.addItem(withTitle: "Focus Pane Right", action: #selector(TerminalHostViewController.focusPaneRight(_:)), keyEquivalent: "")
        focusRight.keyEquivalentModifierMask = [.command, .option]
        focusRight.keyEquivalent = "\u{F703}"
        focusRight.target = terminal
        let focusUp = shellMenu.addItem(withTitle: "Focus Pane Up", action: #selector(TerminalHostViewController.focusPaneUp(_:)), keyEquivalent: "")
        focusUp.keyEquivalentModifierMask = [.command, .option]
        focusUp.keyEquivalent = "\u{F700}"
        focusUp.target = terminal
        let focusDown = shellMenu.addItem(withTitle: "Focus Pane Down", action: #selector(TerminalHostViewController.focusPaneDown(_:)), keyEquivalent: "")
        focusDown.keyEquivalentModifierMask = [.command, .option]
        focusDown.keyEquivalent = "\u{F701}"
        focusDown.target = terminal
        let reopenView = shellMenu.addItem(
            withTitle: "Reopen Closed Tab",
            action: #selector(TerminalHostViewController.reopenClosedView(_:)),
            keyEquivalent: "t"
        )
        reopenView.keyEquivalentModifierMask = [.command, .shift]
        reopenView.target = terminal
        let closeView = shellMenu.addItem(
            withTitle: "Close Tab",
            action: #selector(AppDelegate.closeActiveContext(_:)),
            keyEquivalent: "w"
        )
        closeView.target = self
        shellMenu.addItem(.separator())
        let terminateSession = shellMenu.addItem(
            withTitle: "Terminate Session…",
            action: #selector(TerminalHostViewController.terminateSession(_:)),
            keyEquivalent: "w"
        )
        terminateSession.keyEquivalentModifierMask = [.command, .shift]
        terminateSession.target = terminal
        shellMenu.addItem(.separator())
        let previousTab = shellMenu.addItem(withTitle: "Previous Tab", action: #selector(TerminalHostViewController.selectPreviousTab(_:)), keyEquivalent: "[")
        previousTab.keyEquivalentModifierMask = [.command, .shift]
        previousTab.target = terminal
        let nextTab = shellMenu.addItem(withTitle: "Next Tab", action: #selector(TerminalHostViewController.selectNextTab(_:)), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        nextTab.target = terminal
        shellMenu.addItem(.separator())
        let directTabs = NSMenu(title: "Select Tab")
        for command in NativeTerminalShortcutPolicy.directTabCommands() {
            let item = directTabs.addItem(
                withTitle: "Select Tab \(command.commandNumber)",
                action: #selector(TerminalHostViewController.selectTabByNumber(_:)),
                keyEquivalent: command.keyEquivalent
            )
            item.target = terminal
            item.tag = command.commandNumber
        }
        let directTabsItem = NSMenuItem(title: "Select Tab", action: nil, keyEquivalent: "")
        directTabsItem.submenu = directTabs
        shellMenu.addItem(directTabsItem)
        shellMenu.addItem(.separator())
        let clearScreen = shellMenu.addItem(
            withTitle: MacCommandAccessibility.clearScreen.title,
            action: #selector(TerminalHostViewController.clearTerminalScreen(_:)),
            keyEquivalent: MacCommandAccessibility.clearScreen.keyEquivalent
        )
        MacCommandAccessibility.apply(MacCommandAccessibility.clearScreen, to: clearScreen)
        clearScreen.target = terminal
        shellMenu.addItem(.separator())
        let renameTab = shellMenu.addItem(
            withTitle: "Rename Tab…",
            action: #selector(TerminalHostViewController.renameSelectedTab(_:)),
            keyEquivalent: ""
        )
        renameTab.target = terminal
        let moveTabLeft = shellMenu.addItem(
            withTitle: "Move Tab Left",
            action: #selector(TerminalHostViewController.moveSelectedTabLeft(_:)),
            keyEquivalent: ""
        )
        moveTabLeft.target = terminal
        let moveTabRight = shellMenu.addItem(
            withTitle: "Move Tab Right",
            action: #selector(TerminalHostViewController.moveSelectedTabRight(_:)),
            keyEquivalent: ""
        )
        moveTabRight.target = terminal
        shellMenu.addItem(.separator())
        let focusSources = shellMenu.addItem(withTitle: "Focus Connections", action: #selector(MainToolbarController.showSessionsAndFocus(_:)), keyEquivalent: "1")
        focusSources.keyEquivalentModifierMask = [.command, .option]
        focusSources.target = toolbar
        let focusTerminal = shellMenu.addItem(withTitle: "Focus Terminal", action: #selector(TerminalHostViewController.focusTerminal(_:)), keyEquivalent: "2")
        focusTerminal.keyEquivalentModifierMask = [.command, .option]
        focusTerminal.target = terminal
        let focusAgentComposer = shellMenu.addItem(
            withTitle: "Message Focused Agent…",
            action: #selector(AppDelegate.focusFocusedAgentComposer(_:)),
            keyEquivalent: "\r"
        )
        focusAgentComposer.keyEquivalentModifierMask = [.command, .option]
        focusAgentComposer.target = self
        focusAgentComposer.toolTip = "Opens the exact agent bound to this pane, or explains why no agent is linked"
        shellItem.submenu = shellMenu
        menu.addItem(shellItem)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAll = editMenu.addItem(
            withTitle: MacCommandAccessibility.selectAll.title,
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: MacCommandAccessibility.selectAll.keyEquivalent
        )
        MacCommandAccessibility.apply(MacCommandAccessibility.selectAll, to: selectAll)
        editMenu.addItem(.separator())
        let find = editMenu.addItem(
            withTitle: MacCommandAccessibility.find.title,
            action: #selector(TerminalHostViewController.showFind(_:)),
            keyEquivalent: MacCommandAccessibility.find.keyEquivalent
        )
        MacCommandAccessibility.apply(MacCommandAccessibility.find, to: find)
        find.target = terminal
        let findNext = editMenu.addItem(
            withTitle: MacCommandAccessibility.findNext.title,
            action: #selector(TerminalHostViewController.findNext(_:)),
            keyEquivalent: MacCommandAccessibility.findNext.keyEquivalent
        )
        MacCommandAccessibility.apply(MacCommandAccessibility.findNext, to: findNext)
        findNext.target = terminal
        let findPrevious = editMenu.addItem(
            withTitle: MacCommandAccessibility.findPrevious.title,
            action: #selector(TerminalHostViewController.findPrevious(_:)),
            keyEquivalent: MacCommandAccessibility.findPrevious.keyEquivalent
        )
        MacCommandAccessibility.apply(MacCommandAccessibility.findPrevious, to: findPrevious)
        findPrevious.target = terminal
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        let toggleSessions = viewMenu.addItem(
            withTitle: "Toggle Connections",
            action: #selector(MainToolbarController.toggleSessions(_:)),
            keyEquivalent: "s"
        )
        toggleSessions.keyEquivalentModifierMask = [.command, .control]
        toggleSessions.target = toolbar
        viewMenu.addItem(.separator())
        let increaseText = viewMenu.addItem(
            withTitle: MacCommandAccessibility.makeTextBigger.title,
            action: #selector(increaseApplicationTextSize(_:)),
            keyEquivalent: MacCommandAccessibility.makeTextBigger.keyEquivalent
        )
        MacCommandAccessibility.apply(MacCommandAccessibility.makeTextBigger, to: increaseText)
        increaseText.target = self
        let decreaseText = viewMenu.addItem(
            withTitle: MacCommandAccessibility.makeTextSmaller.title,
            action: #selector(decreaseApplicationTextSize(_:)),
            keyEquivalent: MacCommandAccessibility.makeTextSmaller.keyEquivalent
        )
        MacCommandAccessibility.apply(MacCommandAccessibility.makeTextSmaller, to: decreaseText)
        decreaseText.target = self
        let actualSize = viewMenu.addItem(
            withTitle: MacCommandAccessibility.actualSize.title,
            action: #selector(resetApplicationTextSize(_:)),
            keyEquivalent: MacCommandAccessibility.actualSize.keyEquivalent
        )
        MacCommandAccessibility.apply(MacCommandAccessibility.actualSize, to: actualSize)
        actualSize.target = self
        viewMenu.addItem(.separator())
        let toggleFullScreen = viewMenu.addItem(
            withTitle: MacCommandAccessibility.toggleFullScreen.title,
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: MacCommandAccessibility.toggleFullScreen.keyEquivalent
        )
        MacCommandAccessibility.apply(MacCommandAccessibility.toggleFullScreen, to: toggleFullScreen)
        viewMenu.addItem(.separator())
        let scrollToTop = viewMenu.addItem(
            withTitle: MacCommandAccessibility.scrollToTop.title,
            action: #selector(TerminalHostViewController.scrollTerminalToTop(_:)),
            keyEquivalent: MacCommandAccessibility.scrollToTop.keyEquivalent
        )
        MacCommandAccessibility.apply(MacCommandAccessibility.scrollToTop, to: scrollToTop)
        scrollToTop.target = terminal
        let scrollToBottom = viewMenu.addItem(
            withTitle: MacCommandAccessibility.scrollToBottom.title,
            action: #selector(TerminalHostViewController.scrollTerminalToBottom(_:)),
            keyEquivalent: MacCommandAccessibility.scrollToBottom.keyEquivalent
        )
        MacCommandAccessibility.apply(MacCommandAccessibility.scrollToBottom, to: scrollToBottom)
        scrollToBottom.target = terminal
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)

        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)

        NSApp.mainMenu = menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
