import Combine
import CoreAudio
import Foundation
import os

struct MacAudioOutputDevice: Equatable, Sendable {
    let id: UInt32
    let name: String
    let transportType: UInt32?
    let isHeadphones: Bool
}

@MainActor
final class MacAudioOutputMonitor: ObservableObject {
    @Published private(set) var output: MacAudioOutputDevice?

    private let logger = Logger(subsystem: "com.fpieringer.Keyway", category: "Playback")
    private var listener: AudioObjectPropertyListenerBlock?
    private var isStarted = false

    func start() {
        guard !isStarted else {
            return
        }

        isStarted = true
        refresh()

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.refresh()
            }
        }
        self.listener = listener

        var address = Self.defaultOutputDeviceAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            listener
        )
        if status != noErr {
            self.listener = nil
            isStarted = false
            logger.error("KeywayMacAudioOutput listener=failed status=\(status, privacy: .public)")
        }
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false

        if let listener {
            var address = Self.defaultOutputDeviceAddress
            let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                listener
            )
            if status != noErr {
                logger.error("KeywayMacAudioOutput listener=stop_failed status=\(status, privacy: .public)")
            }
        }
        listener = nil
        output = nil
    }

    func refresh() {
        guard let deviceID = Self.defaultOutputDeviceID() else {
            if output != nil {
                output = nil
            }
            logger.info("KeywayMacAudioOutput state=unavailable")
            return
        }

        let name = Self.deviceName(deviceID: deviceID) ?? "Mac audio output"
        let transportType = Self.transportType(deviceID: deviceID)
        let nextOutput = MacAudioOutputDevice(
            id: UInt32(deviceID),
            name: name,
            transportType: transportType,
            isHeadphones: Self.isHeadphoneOutput(name: name)
        )

        guard output != nextOutput else {
            return
        }

        output = nextOutput
        logger.info("KeywayMacAudioOutput state=changed id=\(nextOutput.id, privacy: .public) name=\(nextOutput.name, privacy: .public) headphones=\(nextOutput.isHeadphones, privacy: .public)")
    }

    private static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var address = defaultOutputDeviceAddress
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }

        return deviceID
    }

    private static func deviceName(deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &name
        )

        guard status == noErr, let name else {
            return nil
        }

        return name.takeUnretainedValue() as String
    }

    private static func transportType(deviceID: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &transportType
        )

        guard status == noErr else {
            return nil
        }

        return transportType
    }

    private static func isHeadphoneOutput(name: String) -> Bool {
        let normalizedName = name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        let headphoneNameMarkers = [
            "headphone",
            "headset",
            "airpods",
            "earphone",
            "earbuds",
            "buds",
            "beats",
            "wh-",
            "xm4",
            "xm5",
            "quietcomfort",
            "qc45",
            "qc35",
            "momentum",
        ]
        let nameLooksLikeHeadphones = headphoneNameMarkers.contains {
            normalizedName.contains($0)
        }
        return nameLooksLikeHeadphones
    }
}
