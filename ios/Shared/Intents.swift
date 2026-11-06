import AppIntents

/// The widgets' button: connects or disconnects, whichever the VPN isn't.
struct ToggleTunnelIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Routey On or Off"

    func perform() async throws -> some IntentResult {
        let state = await TunnelControl.state()
        try await setTunnel(on: !state.isOn)
        return .result()
    }
}

/// The Control Center toggle.
struct SetTunnelIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn Routey On or Off"

    @Parameter(title: "On")
    var value: Bool

    func perform() async throws -> some IntentResult {
        try await setTunnel(on: value)
        return .result()
    }
}

struct ConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect Routey"

    func perform() async throws -> some IntentResult {
        try await setTunnel(on: true)
        return .result()
    }
}

struct DisconnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect Routey"

    func perform() async throws -> some IntentResult {
        try await setTunnel(on: false)
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
