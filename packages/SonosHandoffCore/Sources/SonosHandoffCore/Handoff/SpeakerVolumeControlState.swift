public enum SpeakerVolumeControlDefaults {
    public static let step = 5
}

public struct SpeakerVolumeControlState: Equatable, Sendable {
    public private(set) var value = 0.0
    public private(set) var muted = false
    public private(set) var outputFixed = false
    public private(set) var hasStatus = false
    public private(set) var isBusy = false

    public init() {}

    public var roundedValue: Int {
        Int(value.rounded())
    }

    public mutating func setBusy() {
        isBusy = true
    }

    public mutating func clearStatus() {
        value = 0
        muted = false
        outputFixed = false
        hasStatus = false
        isBusy = false
    }

    public mutating func setSliderValue(locationX: Double, width: Double) {
        let boundedWidth = max(width, 1)
        let boundedX = min(max(locationX, 0), boundedWidth)
        value = (boundedX / boundedWidth) * 100
    }

    public mutating func applyLocalVolume(_ volume: Int, muted: Bool) {
        value = Self.clampedValue(volume)
        self.muted = muted
        hasStatus = true
        isBusy = false
    }

    public mutating func applyMute(_ muted: Bool) {
        self.muted = muted
        hasStatus = true
        isBusy = false
    }

    public mutating func applyStatus(_ status: SpeakerVolumeStatus) {
        value = Self.clampedValue(status.volume)
        muted = status.muted
        outputFixed = status.outputFixed
        hasStatus = true
        isBusy = false
    }

    public mutating func applySnapshot(_ snapshot: SpeakerVolumeSnapshot) {
        value = Self.clampedValue(snapshot.volume)
        muted = snapshot.muted
        outputFixed = snapshot.outputFixed
        hasStatus = true
    }

    private static func clampedValue(_ volume: Int) -> Double {
        Double(min(100, max(0, volume)))
    }
}
