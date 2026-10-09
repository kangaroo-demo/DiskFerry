import Foundation

public enum VolumePolicy: String, Codable, Sendable, CaseIterable {
    case automatic, readOnly, unmanaged
    public var label: String {
        switch self {
        case .automatic: "按通用设置"
        case .readOnly: "保持只读"
        case .unmanaged: "暂不接管"
        }
    }
}

public struct UserPreferences: Codable, Equatable, Sendable {
    public var automaticWriting = false
    public var showMenuBarIcon = true
    public var showActivity = true
    public var checkForUpdates = true
    public var volumePolicies: [String: VolumePolicy] = [:]

    public init() {}
    public func policy(for volume: Volume) -> VolumePolicy {
        volume.preferenceKey.flatMap { volumePolicies[$0] } ?? .automatic
    }
    public mutating func setPolicy(_ policy: VolumePolicy, for volume: Volume) {
        guard let key = volume.preferenceKey else { return }
        if policy == .automatic { volumePolicies.removeValue(forKey: key) }
        else { volumePolicies[key] = policy }
    }
}

/// Preferences are stored locally; demo sessions use an in-memory store.
@MainActor
public final class PreferencesStore {
    private let defaults: UserDefaults?
    private let key = "DiskFerry.preferences.v1"
    public init(defaults: UserDefaults? = .standard) { self.defaults = defaults }
    public func load() -> UserPreferences {
        guard let data = defaults?.data(forKey: key),
              let settings = try? JSONDecoder().decode(UserPreferences.self, from: data) else {
            return UserPreferences()
        }
        return settings
    }
    public func save(_ settings: UserPreferences) throws {
        defaults?.set(try JSONEncoder().encode(settings), forKey: key)
    }
}
