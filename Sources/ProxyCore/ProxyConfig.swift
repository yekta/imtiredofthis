import Foundation

/// What the user sets up: Shadowsocks for the chosen apps, and VLESS for every other app, each on
/// or off. Saved as JSON, and it is the config file that can be imported and exported.
public struct ProxyConfig: Codable, Equatable, Sendable {
    public var shadowsocks: ShadowsocksConfig
    public var vless: VLESSConfig

    public init(shadowsocks: ShadowsocksConfig = ShadowsocksConfig(), vless: VLESSConfig = VLESSConfig()) {
        self.shadowsocks = shadowsocks
        self.vless = vless
    }

    private enum CodingKeys: String, CodingKey {
        case shadowsocks, vless
        case server, apps
    }

    /// Also reads the configs from before VLESS, which were Shadowsocks's alone.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let shadowsocks = try container.decodeIfPresent(ShadowsocksConfig.self, forKey: .shadowsocks) {
            self.shadowsocks = shadowsocks
        } else {
            shadowsocks = ShadowsocksConfig(
                isOn: true,
                server: try container.decodeIfPresent(String.self, forKey: .server) ?? "",
                apps: try container.decodeIfPresent([String].self, forKey: .apps) ?? []
            )
        }
        vless = try container.decodeIfPresent(VLESSConfig.self, forKey: .vless) ?? VLESSConfig()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shadowsocks, forKey: .shadowsocks)
        try container.encode(vless, forKey: .vless)
    }

    /// The server a flow of the app with this signing identifier goes through, if any: Shadowsocks
    /// for its apps, VLESS for the rest.
    public func upstream(for signingIdentifier: String, shadowsocks server: Server?, vless vlessServer: VLESSServer?) -> Upstream? {
        if shadowsocks.isOn, let server, shadowsocks.routes(signingIdentifier) {
            return .shadowsocks(server)
        }
        if vless.isOn, let vlessServer {
            return .vless(vlessServer)
        }
        return nil
    }
}

public struct ShadowsocksConfig: Codable, Equatable, Sendable {
    public var isOn: Bool
    /// The server's `ss://` link.
    public var server: String
    /// The apps' bundle identifiers. An app's helpers, whose identifiers start with the app's and
    /// a dot (Discord's `com.hnc.Discord.helper`), go through too.
    public var apps: [String]

    public init(isOn: Bool = false, server: String = "", apps: [String] = []) {
        self.isOn = isOn
        self.server = server
        self.apps = apps
    }

    private enum CodingKeys: String, CodingKey {
        case isOn = "on", server, apps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isOn = try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? false
        server = try container.decodeIfPresent(String.self, forKey: .server) ?? ""
        apps = try container.decodeIfPresent([String].self, forKey: .apps) ?? []
    }

    public func routes(_ signingIdentifier: String) -> Bool {
        apps.contains { signingIdentifier == $0 || signingIdentifier.hasPrefix($0 + ".") }
    }
}

public struct VLESSConfig: Codable, Equatable, Sendable {
    public var isOn: Bool
    /// The server's `vless://` link.
    public var server: String

    public init(isOn: Bool = false, server: String = "") {
        self.isOn = isOn
        self.server = server
    }

    private enum CodingKeys: String, CodingKey {
        case isOn = "on", server
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isOn = try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? false
        server = try container.decodeIfPresent(String.self, forKey: .server) ?? ""
    }
}

/// What the app asks the proxy while it runs.
public enum ProviderMessage: Codable, Sendable {
    case stats
    case config(ProxyConfig)
}

public enum UpstreamKind: String, Codable, Sendable {
    case shadowsocks
    case vless
}

extension Upstream {
    public var kind: UpstreamKind {
        switch self {
        case .shadowsocks: return .shadowsocks
        case .vless: return .vless
        }
    }
}

/// The proxy's totals since it started, for each kind of server.
public struct ProxyStats: Codable, Equatable, Sendable {
    public var shadowsocks = Totals()
    public var vless = Totals()

    public init() {}

    public subscript(kind: UpstreamKind) -> Totals {
        get { kind == .shadowsocks ? shadowsocks : vless }
        set {
            switch kind {
            case .shadowsocks: shadowsocks = newValue
            case .vless: vless = newValue
            }
        }
    }

    public struct Totals: Codable, Equatable, Sendable {
        public var sent: UInt64 = 0
        public var received: UInt64 = 0
        public var connections = 0
        /// The last error a connection through the server ran into, if the latest one failed.
        public var lastError: String?

        public init() {}
    }
}
