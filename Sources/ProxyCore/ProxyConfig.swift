import Foundation

/// What the user sets up: the server, and the apps that go through it. Saved as JSON, and it is
/// the config file that can be imported and exported.
public struct ProxyConfig: Codable, Equatable, Sendable {
    /// The server's `ss://` link.
    public var server: String
    /// The apps' bundle identifiers. An app's helpers, whose identifiers start with the app's and
    /// a dot (Discord's `com.hnc.Discord.helper`), go through too.
    public var apps: [String]

    public init(server: String = "", apps: [String] = []) {
        self.server = server
        self.apps = apps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        server = try container.decodeIfPresent(String.self, forKey: .server) ?? ""
        apps = try container.decodeIfPresent([String].self, forKey: .apps) ?? []
    }

    public func routes(_ signingIdentifier: String) -> Bool {
        apps.contains { signingIdentifier == $0 || signingIdentifier.hasPrefix($0 + ".") }
    }
}

/// What the app asks the proxy while it runs.
public enum ProviderMessage: Codable, Sendable {
    case stats
    case config(ProxyConfig)
}

/// The proxy's totals since it started.
public struct ProxyStats: Codable, Equatable, Sendable {
    public var sent: UInt64 = 0
    public var received: UInt64 = 0
    public var connections = 0
    /// The last error a connection through the server ran into, if the latest one failed.
    public var lastError: String?

    public init() {}
}
