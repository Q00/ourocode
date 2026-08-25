import AppKit
import Darwin
import Foundation

struct CUAInstallationProbe: Equatable {
    let executablePath: String?
    let bridgePath: String?
    let version: String?
    let accessibilityGranted: Bool
    let screenRecordingGranted: Bool

    var isReady: Bool {
        executablePath != nil && bridgePath != nil && accessibilityGranted
    }
}

enum CUAInstallationLocator {
    static let pinnedVersion = "0.9.1"
    static let installCommand = "CUA_VERSION=v0.9.1 curl -fsSL https://raw.githubusercontent.com/maestrojeong/cua-rs-mcp/main/install.sh | sh"

    static func candidateURLs(
        executableName: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            homeDirectory.appendingPathComponent(".local/bin/\(executableName)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(executableName)"),
            URL(fileURLWithPath: "/usr/local/bin/\(executableName)"),
        ]
    }

    static func firstExecutable(
        named name: String,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        candidateURLs(executableName: name, homeDirectory: homeDirectory).first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    static func parsePermissions(_ output: String) -> (accessibility: Bool, screenRecording: Bool) {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        func value(_ key: String) -> Bool {
            lines.contains { line in
                let fields = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
                return fields.count == 2 && fields[0] == key && fields[1] == "true"
            }
        }
        return (value("accessibility"), value("screen_recording"))
    }
}

final class ComputerUseSettingsViewController: NSViewController {
    private let workQueue = DispatchQueue(
        label: "com.ourolabs.ourocode.cua-settings-probe",
        qos: .userInitiated
    )
    private let statusGlyph = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "Not checked")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(title: "Check again", target: nil, action: nil)
    private let installButton = NSButton(title: "Copy install command", target: nil, action: nil)
    private let accessibilityButton = NSButton(title: "Accessibility…", target: nil, action: nil)
    private let recordingButton = NSButton(title: "Screen Recording…", target: nil, action: nil)
    private var generation = 0
    private var appActivationObserver: NSObjectProtocol?


    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 616, height: 190))
        let title = NSTextField(labelWithString: "Computer Use")
        title.font = OuroTheme.uiFont(size: 17, weight: .semibold)
        title.textColor = OuroTheme.text

        let subtitle = NSTextField(wrappingLabelWithString:
            "One shared Computer Use service lets Ourocode, Ouroboros, and other local MCP sessions drive native Mac apps without moving your pointer or stealing focus."
        )
        subtitle.font = OuroTheme.uiFont(size: 12)
        subtitle.textColor = OuroTheme.muted
        subtitle.maximumNumberOfLines = 2

        refreshButton.target = self
        refreshButton.action = #selector(refresh(_:))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.setAccessibilityLabel("Check Computer Use setup")

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, headerSpacer, refreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let panel = SolidPanelView(cornerRadius: 11)
        panel.translatesAutoresizingMaskIntoConstraints = false
        statusGlyph.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        statusGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        statusGlyph.contentTintColor = OuroTheme.muted
        statusGlyph.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = OuroTheme.uiFont(size: 12.5, weight: .semibold)
        statusLabel.textColor = OuroTheme.text
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = OuroTheme.uiFont(size: 11.5)
        detailLabel.textColor = OuroTheme.muted
        detailLabel.maximumNumberOfLines = 3
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        for button in [installButton, accessibilityButton, recordingButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        installButton.target = self
        installButton.action = #selector(copyInstallCommand(_:))
        installButton.setAccessibilityHelp("Copies the pinned cua-rs 0.9.1 install command. No command runs automatically.")
        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibilitySettings(_:))
        recordingButton.target = self
        recordingButton.action = #selector(openScreenRecordingSettings(_:))

        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [installButton, actionSpacer, accessibilityButton, recordingButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(statusGlyph)
        panel.addSubview(statusLabel)
        panel.addSubview(detailLabel)
        panel.addSubview(actions)
        NSLayoutConstraint.activate([
            statusGlyph.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 15),
            statusGlyph.topAnchor.constraint(equalTo: panel.topAnchor, constant: 15),
            statusGlyph.widthAnchor.constraint(equalToConstant: 10),
            statusGlyph.heightAnchor.constraint(equalToConstant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: statusGlyph.trailingAnchor, constant: 9),
            statusLabel.firstBaselineAnchor.constraint(equalTo: statusGlyph.bottomAnchor, constant: 2),
            statusLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -15),
            detailLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -15),
            detailLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            actions.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            actions.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 10),
            actions.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
        ])

        let stack = NSStackView(views: [header, subtitle, panel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            panel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
        preferredContentSize = root.frame.size
        renderChecking()
    }

    func activate() {
        _ = view
        if appActivationObserver == nil {
            appActivationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh(nil)
            }
        }
        refresh(nil)
    }


    @objc private func refresh(_ sender: Any?) {
        generation += 1
        let requestedGeneration = generation
        renderChecking()
        workQueue.async { [weak self] in
            let probe = Self.probe()
            DispatchQueue.main.async {
                guard let self, self.generation == requestedGeneration else { return }
                self.render(probe)
            }
        }
    }

    deinit {
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
        }
    }

    private static func probe() -> CUAInstallationProbe {
        let executable = CUAInstallationLocator.firstExecutable(named: "cua-rs")
        let bridge = CUAInstallationLocator.firstExecutable(named: "ourocode-cua-mcp-bridge")
        guard let executable else {
            return CUAInstallationProbe(
                executablePath: nil,
                bridgePath: bridge?.path,
                version: nil,
                accessibilityGranted: false,
                screenRecordingGranted: false
            )
        }
        let version = run(executable, arguments: ["--version"], timeout: 2)
        let permissionsOutput = run(executable, arguments: ["permissions"], timeout: 2) ?? ""
        let permissions = CUAInstallationLocator.parsePermissions(permissionsOutput)
        return CUAInstallationProbe(
            executablePath: executable.path,
            bridgePath: bridge?.path,
            version: version?.trimmingCharacters(in: .whitespacesAndNewlines),
            accessibilityGranted: permissions.accessibility,
            screenRecordingGranted: permissions.screenRecording
        )
    }

    private static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        guard !process.isRunning else {
            process.terminate()
            return nil
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile().prefix(8_192), as: UTF8.self)
    }

    private func renderChecking() {
        refreshButton.isEnabled = false
        statusGlyph.contentTintColor = OuroTheme.muted
        statusLabel.stringValue = "Checking Computer Use…"
        detailLabel.stringValue = "Verifying the pinned server, compatibility bridge, and macOS privacy grants."
    }

    private func render(_ probe: CUAInstallationProbe) {
        refreshButton.isEnabled = true
        if probe.isReady {
            statusGlyph.contentTintColor = OuroTheme.mint
            statusLabel.stringValue = "Ready · \(probe.version ?? "cua-rs")"
            detailLabel.stringValue = probe.screenRecordingGranted
                ? "Accessibility and Screen Recording are granted. The shared CUA MCP service is available to local sessions with human-yield safety enabled."
                : "Accessibility is granted. Native app control works across local MCP sessions; grant Screen Recording for screenshots and visual safety checks."
        } else if probe.executablePath == nil || probe.bridgePath == nil {
            statusGlyph.contentTintColor = .systemOrange
            statusLabel.stringValue = "Install required"
            detailLabel.stringValue = "Install the pinned cua-rs server and Ourocode compatibility bridge, then check again. Nothing is downloaded from this screen."
        } else {
            statusGlyph.contentTintColor = .systemOrange
            statusLabel.stringValue = "Privacy permission required"
            detailLabel.stringValue = "Grant Accessibility to the app launching cua-rs. Screen Recording is optional but required for screenshots. Restart Ourocode after changing a grant."
        }
        statusLabel.setAccessibilityValue(statusLabel.stringValue)
        detailLabel.setAccessibilityValue(detailLabel.stringValue)
        NSAccessibility.post(element: statusLabel, notification: .valueChanged)
    }

    @objc private func copyInstallCommand(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CUAInstallationLocator.installCommand, forType: .string)
        installButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.installButton.title = "Copy install command"
        }
    }

    @objc private func openAccessibilitySettings(_ sender: Any?) {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openScreenRecordingSettings(_ sender: Any?) {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func openSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}
