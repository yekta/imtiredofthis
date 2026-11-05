import AppKit
import ProxyCore
import SwiftUI
import UniformTypeIdentifiers

/// The panel that drops down from the menu bar item.
struct SettingsView: View {
    static let size = NSSize(width: 420, height: 620)

    @Bindable var model: AppModel
    @State private var tab = UpstreamKind.shadowsocks
    /// Set when a switch is flipped before its setup is done.
    @State private var showsMissingSteps: Set<UpstreamKind> = []

    var body: some View {
        Form {
            Section {
                Picker("Server", selection: $tab) {
                    Text(UpstreamKind.shadowsocks.title).tag(UpstreamKind.shadowsocks)
                    Text(UpstreamKind.vless.title).tag(UpstreamKind.vless)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fillsWidth()

                Header(model: model, kind: tab, showsMissingSteps: $showsMissingSteps)
            }

            if !model.canTurnOn(tab) {
                GettingStartedSection(model: model, kind: tab, showsMissingSteps: showsMissingSteps.contains(tab))
            }

            SetupSection(proxy: model.proxy)

            if model.proxy.isConnected, model.isOn(tab) {
                TrafficSection(traffic: model.proxy.traffic[tab] ?? ProxyController.Traffic())
            }

            ServerSection(model: model, kind: tab)
                .id(tab)

            if tab == .shadowsocks {
                AppsSection(model: model)
            }

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
    let kind: UpstreamKind
    @Binding var showsMissingSteps: Set<UpstreamKind>

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
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
            Toggle(kind.title, isOn: Binding(
                get: { model.isOn(kind) || model.isTurningOn(kind) },
                set: { on in
                    guard !on || model.canTurnOn(kind) else {
                        showsMissingSteps.insert(kind)
                        return
                    }
                    model.setOn(kind, on)
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
        guard model.isOn(kind) else {
            guard model.canTurnOn(kind) else { return ("Set it up below to turn it on", .secondary) }
            return model.isTurningOn(kind) ? ("Turning on…", .orange) : ("Off", .secondary)
        }
        switch proxy.status {
        case .connected:
            guard proxy.traffic[kind]?.isServerReachable ?? true else { return ("Can't reach the server", .red) }
            return (routing, .green)
        case .connecting, .reasserting: return ("Connecting…", .orange)
        case .disconnecting: return ("Turning off…", .secondary)
        default: return ("Waiting for the network", .orange)
        }
    }

    private var routing: String {
        switch kind {
        case .shadowsocks:
            let count = model.config.shadowsocks.apps.count
            return "Routing \(count) \(count == 1 ? "app" : "apps")"
        case .vless:
            return model.isOn(.shadowsocks) ? "Routing every other app" : "Routing every app"
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
    let kind: UpstreamKind
    let showsMissingSteps: Bool

    var body: some View {
        Section {
            switch kind {
            case .shadowsocks:
                Step(number: 1, title: "Paste your server's ss:// link", detail: "In Server, below, then click Save.",
                     isDone: (try? model.shadowsocksServer?.get()) != nil, isMissing: showsMissingSteps)
                Step(number: 2, title: "Add the apps to send through it", detail: "In Apps, below: Add App…, then Discord, for example.",
                     isDone: !model.config.shadowsocks.apps.isEmpty, isMissing: showsMissingSteps)
                Step(number: 3, title: "Turn it on", detail: "With the switch above. The first time, macOS asks you to allow it.",
                     isDone: false, isMissing: false)
            case .vless:
                Step(number: 1, title: "Paste your server's vless:// link", detail: "In Server, below, then click Save.",
                     isDone: (try? model.vlessServer?.get()) != nil, isMissing: showsMissingSteps)
                Step(number: 2, title: "Turn it on", detail: "With the switch above. Every app goes through it, except those Shadowsocks sends.",
                     isDone: false, isMissing: false)
            }
        } header: {
            Text("Get Started")
        } footer: {
            if showsMissingSteps {
                Text(kind == .shadowsocks ? "Do steps 1 and 2 first, then the switch turns on." : "Do step 1 first, then the switch turns on.")
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
    let traffic: ProxyController.Traffic

    var body: some View {
        Section {
            HStack(spacing: 0) {
                Metric(title: "Upload", symbol: "arrow.up", value: speed(traffic.upload))
                Divider()
                Metric(title: "Download", symbol: "arrow.down", value: speed(traffic.download))
                Divider()
                Metric(title: "Latency", symbol: "timer", value: latency)
            }
            .padding(.vertical, 4)
            if let error = traffic.serverError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("\(traffic.connections) \(traffic.connections == 1 ? "connection" : "connections") open through the server.")
                .settingsFooter()
        }
    }

    private var latency: String {
        guard let latency = traffic.latency else { return "—" }
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
    let kind: UpstreamKind
    @State private var draft = ""
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Section {
            if isEditing || link.isEmpty {
                TextField("Server link", text: $draft, prompt: Text(kind == .shadowsocks ? "ss://…" : "vless://…"))
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
                    if !link.isEmpty {
                        Button("Cancel") { isEditing = false }
                    }
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.isEmpty || draftError != nil)
                }
            } else {
                switch summary {
                case let .success(server):
                    LabeledContent {
                        Button("Change…", action: edit)
                    } label: {
                        Text(server.title)
                        Text(server.detail)
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
            switch kind {
            case .shadowsocks:
                Text("Your Shadowsocks server's ss:// link. aes-128-gcm, aes-256-gcm, chacha20-ietf-poly1305 and the 2022-blake3 AES ciphers work.")
                    .settingsFooter()
            case .vless:
                Text("Your VLESS server's vless:// link: REALITY over TCP, with the xtls-rprx-vision flow or none, like the link Xray's setup gives you.")
                    .settingsFooter()
            }
        }
    }

    private var link: String {
        kind == .shadowsocks ? model.config.shadowsocks.server : model.config.vless.server
    }

    private var summary: Result<(title: String, detail: String), Error>? {
        switch kind {
        case .shadowsocks:
            return model.shadowsocksServer?.map { ($0.name ?? $0.host, "\($0.host):\(String($0.port)) · \($0.method.rawValue)") }
        case .vless:
            return model.vlessServer?.map { ($0.name ?? $0.host, "\($0.host):\(String($0.port)) · REALITY as \($0.serverName)") }
        }
    }

    private var draftError: String? {
        guard !draft.isEmpty else { return nil }
        do {
            switch kind {
            case .shadowsocks: _ = try Server(link: draft)
            case .vless: _ = try VLESSServer(link: draft)
            }
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
        let link = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .shadowsocks: model.config.shadowsocks.server = link
        case .vless: model.config.vless.server = link
        }
        draft = ""
        isEditing = false
    }
}

private struct AppsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            if model.config.shadowsocks.apps.isEmpty {
                Text("No apps yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.config.shadowsocks.apps.map(AppEntry.init(bundleID:))) { app in
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
            Text("Only these apps and their helpers go through the server, over TCP and UDP, DNS included. Everything else connects as usual, or through VLESS when it is on. An app that was already open needs a restart.")
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

private extension View {
    /// Stretches the segments across the row; macOS 15 keeps them at their own width.
    @ViewBuilder
    func fillsWidth() -> some View {
        if #available(macOS 26, *) {
            buttonSizing(.flexible)
        } else {
            self
        }
    }
}
