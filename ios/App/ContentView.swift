import ProxyCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            Form {
                ConnectionSection(model: model)
                if case .connected = model.state {
                    TrafficSection(traffic: model.traffic)
                }
                ServerSection(model: model)
                Section {
                    Button("Import Config…") { isImporting = true }
                    ShareLink(item: ConfigFile(config: model.config), preview: SharePreview("Routey.json")) {
                        Text("Export Config…")
                    }
                } footer: {
                    Text("The same config file as Routey on the Mac. Only its VLESS server is used here.")
                }
            }
            .navigationTitle("Routey")
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                do {
                    try model.importConfig(from: result.get())
                } catch {
                    model.error = error.localizedDescription
                }
            }
        }
    }
}

private struct ConnectionSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.state.isOn }, set: { model.setOn($0) })) {
                Text("VPN")
                StatusText(state: model.state)
            }
            .disabled(model.isBusy || model.state == .notSetUp)
            if let error = model.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Every app goes through your VLESS server, over TCP and UDP, DNS included. Your local network stays direct.")
        }
    }
}

private struct TrafficSection: View {
    let traffic: AppModel.Traffic

    var body: some View {
        Section {
            LabeledContent("Upload", value: speed(traffic.upload))
            LabeledContent("Download", value: speed(traffic.download))
            LabeledContent("Latency", value: latency)
            if let error = traffic.serverError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Traffic")
        } footer: {
            Text("\(traffic.connections) \(traffic.connections == 1 ? "connection" : "connections") open through the server.")
        }
        .monospacedDigit()
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

private struct ServerSection: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @State private var isEditing = false
    @State private var linkError: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        Section {
            if isEditing || model.server == nil {
                TextField("Server link", text: $draft, prompt: Text("vless://…"), axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .focused($isFocused)
                    .onSubmit(save)
                if let linkError {
                    Text(linkError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Button("Save", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.server != nil {
                    Button("Cancel", role: .cancel) { isEditing = false }
                }
            } else {
                switch model.server {
                case let .success(server):
                    LabeledContent {
                        Button("Change", action: edit)
                    } label: {
                        Text(server.name ?? server.host)
                        Text("\(server.host):\(String(server.port)) · REALITY as \(server.serverName)")
                    }
                case let .failure(error):
                    LabeledContent {
                        Button("Change", action: edit)
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
            Text("Your VLESS server's vless:// link: REALITY over TCP, with the xtls-rprx-vision flow or none, like the link Xray's setup gives you.")
        }
    }

    private func edit() {
        draft = ""
        linkError = nil
        isEditing = true
        isFocused = true
    }

    private func save() {
        let link = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        linkError = model.useLink(link)
        guard linkError == nil else { return }
        draft = ""
        isEditing = false
        isFocused = false
    }
}

/// The config, shared as a JSON file.
private struct ConfigFile: Transferable {
    let config: ProxyConfig

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { file in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(file.config)
        }
        .suggestedFileName("Routey.json")
    }
}
