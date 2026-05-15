import Foundation

public struct TargetResolver: Sendable {
    public init() {}

    public func resolve(alias: String, in config: AppConfig) -> SavedTarget? {
        config.targets.first(where: { $0.alias.caseInsensitiveCompare(alias) == .orderedSame })
    }
}
