import AppIntents

/// Opens Routey and connects from there, as the widgets' Connect button. Without a server yet,
/// it only opens the app.
struct ConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect Routey"
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        guard ConfigStore.server != nil else { return .result() }
        try await setTunnel(on: true)
        return .result()
    }
}

/// Disconnects in the background, or with Routey open if iOS won't let it from there.
struct DisconnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect Routey"
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    func perform() async throws -> some IntentResult {
        do {
            try await setTunnel(on: false)
        } catch {
            try await continueInForeground(alwaysConfirm: false)
            try await setTunnel(on: false)
        }
        return .result()
    }
}

/// The Control Center toggle: turning it on opens Routey to connect, turning it off disconnects
/// where it is.
struct SetTunnelIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn Routey On or Off"
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "On")
    var value: Bool

    func perform() async throws -> some IntentResult {
        if value {
            try await continueInForeground(alwaysConfirm: false)
            guard ConfigStore.server != nil else { return .result() }
        }
        try await setTunnel(on: value)
        return .result()
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
