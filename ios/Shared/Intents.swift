import AppIntents

/// Connects in the background, or with Routey open if iOS won't let it from there, as when it
/// first asks to add the VPN configuration. Without a server yet, it only opens the app.
struct ConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect Routey"
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    func perform() async throws -> some IntentResult {
        try await setTunnelOrOpen(on: true)
        return .result()
    }
}

/// Disconnects in the background, or with Routey open if iOS won't let it from there.
struct DisconnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect Routey"
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    func perform() async throws -> some IntentResult {
        try await setTunnelOrOpen(on: false)
        return .result()
    }
}

/// The Control Center toggle.
struct SetTunnelIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn Routey On or Off"
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "On")
    var value: Bool

    func perform() async throws -> some IntentResult {
        try await setTunnelOrOpen(on: value)
        return .result()
    }
}

private extension AppIntent {
    /// Connects or disconnects where it is, and opens Routey to try again there if that fails.
    func setTunnelOrOpen(on: Bool) async throws {
        do {
            try await setTunnel(on: on)
        } catch {
            try await continueInForeground(alwaysConfirm: false)
            guard ConfigStore.server != nil else { return }
            try await setTunnel(on: on)
        }
    }
}

/// Waits for the VPN to settle, so the widgets show where it landed rather than "Connecting".
private func setTunnel(on: Bool) async throws {
    defer { TunnelControl.reloadWidgets() }
    if on {
        try await TunnelControl.connect()
    } else {
        try await TunnelControl.disconnect()
    }
    _ = await TunnelControl.settledState()
}
