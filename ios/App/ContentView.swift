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
                    if let data = try? model.exportedConfig() {
                        ShareLink(item: ConfigFile(data: data), preview: SharePreview("Routey.json")) {
                            Text("Export Config…")
                        }
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
    @State private var linkError: String?

    var body: some View {
        Section {
            switch model.server {
            case let .success(server):
                LabeledContent {
                    EmptyView()
                } label: {
                    Text(server.name ?? server.host)
                    Text("\(server.host):\(String(server.port)) · REALITY as \(server.serverName)")
                }
            case let .failure(error):
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("The saved link doesn't work")
                    Text(error.localizedDescription)
                }
            case nil:
                Text("No server yet")
                    .foregroundStyle(.secondary)
            }
            PasteButton(payloadType: String.self) { strings in
                guard let link = strings.first else { return }
                Task { @MainActor in
                    linkError = model.useLink(link)
                }
            }
            if let linkError {
                Text(linkError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Copy your VLESS server's vless:// link, then paste it here: REALITY over TCP, with the xtls-rprx-vision flow or none, like the link Xray's setup gives you.")
        }
    }
}

/// The config, shared as a JSON file.
private struct ConfigFile: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName("Routey.json")
    }
}
