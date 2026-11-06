import SwiftUI

/// "Connected · 12:34", "Connecting…" or "Off".
struct StatusText: View {
    let state: TunnelState

    var body: some View {
        switch state {
        case .notSetUp:
            Text("Not set up")
        case .off:
            Text("Off")
        case .connecting:
            Text("Connecting…")
        case .disconnecting:
            Text("Disconnecting…")
        case let .connected(since?):
            Text("Connected · \(Text(since, style: .timer))")
        case .connected(nil):
            Text("Connected")
        }
    }
}
