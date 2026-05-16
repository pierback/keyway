import Foundation

public struct TargetResolver: Sendable {
    private let outputPreferenceResolver = SonosOutputPreferenceResolver()

    public init() {}

    public func resolve(alias: String, in config: AppConfig) -> SavedTarget? {
        outputPreferenceResolver.target(alias: alias, in: config)
    }
}
