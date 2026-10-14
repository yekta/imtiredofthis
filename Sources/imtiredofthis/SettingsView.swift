import AppKit
import ProxyCore
import SwiftUI
import UniformTypeIdentifiers

/// The panel that drops down from the menu bar item.
struct SettingsView: View {
    static let size = NSSize(width: 420, height: 620)

    @Bindable var model: AppModel
    /// Set when the switch is flipped before the server and apps are in.
    @State private var showsMissingSteps = false

    var body: some View {
        Form {
            Section {
                Header(model: model, showsMissingSteps: $showsMissingSteps)
            }

            if !model.canTurnOn {
                GettingStartedSection(model: model, showsMissingSteps: showsMissingSteps)
            }

            SetupSection(proxy: model.proxy)

            if model.proxy.isConnected {
                TrafficSection(proxy: model.proxy)
            }

            ServerSection(model: model)

            AppsSection(model: model)

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let error = model.loginItemError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Import Config…", action: importConfig)
                    Button("Export Config…", action: exportConfig)
                }
            } footer: {
                Text("The proxy stays on through restarts, even with this app quit, until you turn it off.")
                    .settingsFooter()
            }

            UpdateSection(model: model)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.importConfig(from: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "imtiredofthis.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportConfig(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

private struct Header: View {
    @Bindable var model: AppModel
    @Binding var showsMissingSteps: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("imtiredofthis")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 7, height: 7)
                    Text(status.text)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if model.proxy.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Toggle("Proxy", isOn: Binding(
                get: { model.proxy.isEnabled || model.proxy.isTurningOn },
                set: { enabled in
                    guard !enabled || model.canTurnOn else {
                        showsMissingSteps = true
                        return
                    }
                    model.setEnabled(enabled)
                }
            ))
            .labelsHidden()
            .disabled(model.proxy.isBusy)
        }
        .padding(.vertical, 2)
    }

    private var status: (text: String, color: Color) {
        let proxy = model.proxy
        switch proxy.setup {
        case .installing: return ("Installing the proxy…", .orange)
        case .needsApproval: return ("Allow it in System Settings", .orange)
        case .needsApplicationsFolder: return ("Needs to be in Applications", .orange)
        case .needsRestart: return ("Restart your Mac to finish", .orange)
        case .failed: return ("Couldn't install the proxy", .red)
        case .ready: break
        }
        if proxy.isAskingToAddConfiguration {
            return ("Click Allow on macOS's popup", .orange)
        }
        guard model.canTurnOn else { return ("Set it up below to turn it on", .secondary) }
        guard proxy.isEnabled else { return proxy.isTurningOn ? ("Turning on…", .orange) : ("Off", .secondary) }
        switch proxy.status {
        case .connected:
            guard proxy.isServerReachable else { return ("Can't reach the server", .red) }
            let count = model.config.apps.count
            return ("Routing \(count) \(count == 1 ? "app" : "apps")", .green)
        case .connecting, .reasserting: return ("Connecting…", .orange)
        case .disconnecting: return ("Turning off…", .secondary)
        default: return ("Waiting for the network", .orange)
        }
    }
}

private struct SetupSection: View {
    let proxy: ProxyController

    var body: some View {
        if let error = proxy.error {
            Notice(title: "Couldn't turn it on", detail: error, color: .red)
        }
        switch proxy.setup {
        case .needsApproval:
            Notice(
                title: "Allow imtiredofthis in System Settings",
                detail: "macOS asks once. Click Open System Settings on its popup, turn on imtiredofthis and enter your password. Without the popup: System Settings → General → Login Items & Extensions → Extensions → By Category → ⓘ next to Network Extensions.",
                color: .orange,
                action: ("Open System Settings", proxy.openApprovalSettings)
            )
        case .needsApplicationsFolder:
            Notice(
                title: "Move imtiredofthis to Applications",
                detail: "macOS only installs the proxy from an app in the Applications folder. Move it there, open it again and turn it on.",
                color: .orange
            )
        case .needsRestart:
            Notice(title: "Restart your Mac", detail: "macOS finishes installing the proxy when it starts again.", color: .orange)
        case let .failed(message):
            Notice(title: "Couldn't install the proxy", detail: message, color: .red)
        case .ready, .installing:
            if proxy.isAskingToAddConfiguration {
                Notice(
                    title: "Click Allow",
                    detail: "macOS asks once whether imtiredofthis may add its proxy configuration. Click Allow on that popup, and it turns on.",
                    color: .orange
                )
            }
        }
    }
}

/// What to do before the switch can turn on, ticked off as it gets done.
private struct GettingStartedSection: View {
    let model: AppModel
    let showsMissingSteps: Bool

    var body: some View {
        Section {
            Step(number: 1, title: "Paste your server's ss:// link", detail: "In Server, below, then click Save.",
                 isDone: model.validServer != nil, isMissing: showsMissingSteps)
            Step(number: 2, title: "Add the apps to send through it", detail: "In Apps, below: Add App…, then Discord, for example.",
                 isDone: !model.config.apps.isEmpty, isMissing: showsMissingSteps)
            Step(number: 3, title: "Turn it on", detail: "With the switch above. The first time, macOS asks you to allow it.",
                 isDone: false, isMissing: false)
        } header: {
            Text("Get Started")
        } footer: {
            if showsMissingSteps {
                Text("Do steps 1 and 2 first, then the switch turns on.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct Step: View {
    let number: Int
    let title: String
    let detail: String
    let isDone: Bool
    let isMissing: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .strikethrough(isDone)
                    .foregroundStyle(isDone ? .secondary : .primary)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: isDone ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(isDone ? .green : isMissing ? .orange : .secondary)
                .font(.title3)
        }
    }
}

private struct Notice: View {
    let title: String
    let detail: String
    let color: Color
    var action: (title: String, run: () -> Void)?

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(color)
            }
            if let action {
                HStack {
                    Spacer()
                    Button(action.title, action: action.run)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

private struct TrafficSection: View {
    let proxy: ProxyController

    var body: some View {
        Section {
            HStack(spacing: 0) {
                Metric(title: "Upload", symbol: "arrow.up", value: speed(proxy.upload))
                Divider()
                Metric(title: "Download", symbol: "arrow.down", value: speed(proxy.download))
                Divider()
                Metric(title: "Latency", symbol: "timer", value: latency)
            }
            .padding(.vertical, 4)
            if let error = proxy.serverError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("\(proxy.connections) \(proxy.connections == 1 ? "connection" : "connections") open through the server.")
                .settingsFooter()
        }
    }

    private var latency: String {
        guard let latency = proxy.latency else { return "—" }
        let milliseconds = Double(latency.components.attoseconds) / 1e15 + Double(latency.components.seconds) * 1000
        return "\(Int(milliseconds.rounded())) ms"
    }

    private func speed(_ bytesPerSecond: Double) -> String {
        "\(Int64(bytesPerSecond).formatted(.byteCount(style: .file)))/s"
    }
}

private struct Metric: View {
    let title: String
    let symbol: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.medium))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ServerSection: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Section {
            if isEditing || model.config.server.isEmpty {
                TextField("Server link", text: $draft, prompt: Text("ss://…"))
                    .labelsHidden()
                    .focused($isFocused)
                    .onSubmit(save)
                if let error = draftError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    if !model.config.server.isEmpty {
                        Button("Cancel") { isEditing = false }
                    }
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.isEmpty || draftError != nil)
                }
            } else {
                switch model.server {
                case let .success(server):
                    LabeledContent {
                        Button("Change…", action: edit)
                    } label: {
                        Text(server.name ?? server.host)
                        Text("\(server.host):\(String(server.port)) · \(server.method.rawValue)")
                    }
                case let .failure(error):
                    LabeledContent {
                        Button("Change…", action: edit)
                    } label: {
                        Text("The saved link doesn't work")
                        Text(error.localizedDescription)
                    }
                case nil:
                    EmptyView()
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Your Shadowsocks server's ss:// link. aes-128-gcm, aes-256-gcm, chacha20-ietf-poly1305 and the 2022-blake3 AES ciphers work.")
                .settingsFooter()
        }
    }

    private var draftError: String? {
        guard !draft.isEmpty else { return nil }
        do {
            _ = try Server(link: draft)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func edit() {
        draft = ""
        isEditing = true
        isFocused = true
    }

    private func save() {
        guard !draft.isEmpty, draftError == nil else { return }
        model.config.server = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        isEditing = false
    }
}

private struct AppsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            if model.config.apps.isEmpty {
                Text("No apps yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.config.apps.map(AppEntry.init(bundleID:))) { app in
                HStack(spacing: 8) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(app.name)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle.fill") {
                        model.remove(app.bundleID)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Stop routing \(app.name)")
                }
            }
            HStack {
                Spacer()
                Menu("Add App…") {
                    ForEach(runningApps()) { app in
                        Button {
                            model.add(app.bundleID)
                        } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: menuIcon(app.icon)) }
                        }
                    }
                    Divider()
                    Button("Choose…", action: chooseApp)
                }
                .fixedSize()
            }
        } header: {
            Text("Apps")
        } footer: {
            Text("Only these apps and their helpers go through the server, over TCP and UDP. Everything else, and anything on your own network, connects as usual.")
                .settingsFooter()
        }
    }

    private func runningApps() -> [AppEntry] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { $0.bundleURL.flatMap(AppEntry.init(url:)) }
            .filter { !model.routes($0.bundleID) && seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func menuIcon(_ icon: NSImage) -> NSImage {
        let sized = icon.copy() as? NSImage ?? icon
        sized.size = NSSize(width: 16, height: 16)
        return sized
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let app = AppEntry(url: url) else { continue }
            model.add(app.bundleID)
        }
    }
}

private struct UpdateSection: View {
    let model: AppModel

    var body: some View {
        let updater = model.updater
        Section {
            if let update = updater.available {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("imtiredofthis \(update.version) is available")
                            Text("You have \(Updater.currentVersion). It restarts once installed.")
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    Spacer()
                    if updater.isInstalling {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Install and Restart") {
                        Task { await updater.install() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.isInstalling)
                }
            }
            HStack {
                Text("Version \(Updater.currentVersion)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check for Updates") {
                    Task { await updater.check() }
                }
                .disabled(updater.isChecking || updater.isInstalling)
            }
            HStack {
                Spacer()
                Button("Quit imtiredofthis") { NSApp.terminate(nil) }
            }
        }
    }
}

private extension Text {
    func settingsFooter() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
