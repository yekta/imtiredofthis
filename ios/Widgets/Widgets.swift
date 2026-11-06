import AppIntents
import ProxyCore
import SwiftUI
import WidgetKit

@main
struct RouteyWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        TunnelToggle()
    }
}

struct StatusEntry: TimelineEntry {
    var date = Date()
    var state = TunnelState.off
    var name = "Routey"
    var host: String?

    static func now() async -> StatusEntry {
        let server = ConfigStore.server
        return StatusEntry(state: await TunnelControl.state(), name: server?.name ?? server?.host ?? "Routey", host: server?.host)
    }
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        Task { completion(await StatusEntry.now()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        Task {
            let entry = await StatusEntry.now()
            // While it connects or disconnects, look again soon for where it lands.
            let settling = entry.state == .connecting || entry.state == .disconnecting
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(settling ? 3 : 30 * 60))))
        }
    }
}

/// The server's name and a button that connects or disconnects with one tap, on the Home Screen
/// and the Lock Screen.
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "org.routey.routey.status", provider: StatusProvider()) { entry in
            StatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Routey")
        .description("Connect with one tap, and see whether Routey is on.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

private struct StatusView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    private var isConnected: Bool {
        if case .connected = entry.state { return true }
        return false
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text(entry.name)
                    .font(.headline)
                    .widgetAccentable()
                StatusText(state: entry.state)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            HStack(spacing: 16) {
                tile
                VStack(alignment: .leading, spacing: 4) {
                    StatusText(state: entry.state)
                        .font(.headline)
                    if let host = entry.host {
                        Text(host)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            tile
        }
    }

    /// The icon, the server's name, and the button.
    private var tile: some View {
        VStack(alignment: .leading) {
            RouteIcon()
                .foregroundStyle(.white)
                .padding(6)
                .frame(width: 32, height: 32)
                .background(isConnected ? Color.green : Color.secondary, in: .rect(cornerRadius: 8))
                .widgetAccentable()
            Spacer(minLength: 4)
            Text(entry.name)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            button
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var button: some View {
        toggle {
            Text(buttonTitle)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(isConnected ? .green : nil)
        .widgetAccentable()
    }

    private var buttonTitle: String {
        switch entry.state {
        case .notSetUp: return "Set Up"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .connected: return "Disconnect"
        case .off: return "Connect"
        }
    }

    /// Connecting opens Routey and connects there; disconnecting happens where it is.
    @ViewBuilder private func toggle(@ViewBuilder label: () -> some View) -> some View {
        if entry.state.isOn {
            Button(intent: DisconnectIntent(), label: label)
        } else {
            Button(intent: ConnectIntent(), label: label)
        }
    }

    @ViewBuilder private var circular: some View {
        if entry.state == .notSetUp {
            ZStack {
                AccessoryWidgetBackground()
                RouteIcon()
                    .padding(12)
            }
        } else {
            toggle {
                ZStack {
                    if isConnected {
                        Circle()
                            .widgetAccentable()
                        RouteIcon()
                            .padding(12)
                            .blendMode(.destinationOut)
                    } else {
                        AccessoryWidgetBackground()
                        RouteIcon()
                            .padding(12)
                    }
                }
                .compositingGroup()
            }
            .buttonStyle(.plain)
        }
    }
}

/// The Control Center, Lock Screen and Action button toggle.
struct TunnelToggle: ControlWidget {
    struct Value {
        var isOn: Bool
        var isSetUp: Bool
    }

    struct Provider: ControlValueProvider {
        var previewValue: Value {
            Value(isOn: false, isSetUp: true)
        }

        func currentValue() async throws -> Value {
            let state = await TunnelControl.state()
            return Value(isOn: state.isOn, isSetUp: state != .notSetUp)
        }
    }

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "org.routey.routey.toggle", provider: Provider()) { value in
            ControlWidgetToggle("Routey", isOn: value.isOn, action: SetTunnelIntent()) { isOn in
                Label(value.isSetUp ? (isOn ? "On" : "Off") : "Set Up", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .tint(.green)
        }
        .displayName("Routey")
        .description("Turns Routey's VPN on and off.")
    }
}
