import Foundation
import SonosHandoffCore

let arguments = Array(CommandLine.arguments.dropFirst())
let optionsWithValues = Set([
    "--login-id",
    "--step",
    "--volume",
    "--spotify-uri",
    "--spotify-device-name",
    "--spotify-device-type",
])
let commands = Set([
    "handoff",
    "playback-status",
    "playback-devices",
    "playback-start",
    "playback-command",
    "sonos-status",
    "volume-up",
    "volume-down",
    "volume-set",
    "volume-status",
    "volume-mute",
    "volume-mute-on",
    "volume-mute-off",
    "volume-zero-muted",
])

if arguments.contains(where: { $0 == "--help" || $0 == "-h" }) {
    printUsage()
    exit(0)
}

var parsedOptions: [String: String] = [:]
var parsedPositionals: [String] = []
var argumentIndex = 0

while argumentIndex < arguments.count {
    let argument = arguments[argumentIndex]
    guard argument.hasPrefix("-") else {
        parsedPositionals.append(argument)
        argumentIndex += 1
        continue
    }

    let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    let optionName = String(parts[0])
    guard optionsWithValues.contains(optionName) else {
        fatalError("Unknown option: \(argument)")
    }

    let value: String
    if parts.count == 2 {
        value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        guard argumentIndex + 1 < arguments.count, !arguments[argumentIndex + 1].hasPrefix("-") else {
            fatalError("Missing value for \(optionName)")
        }
        argumentIndex += 1
        value = arguments[argumentIndex].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !value.isEmpty else {
        fatalError("Missing value for \(optionName)")
    }
    guard parsedOptions[optionName] == nil else {
        fatalError("Duplicate option: \(optionName)")
    }
    parsedOptions[optionName] = value
    argumentIndex += 1
}

let command: String
let positionals: [String]
if let first = parsedPositionals.first, commands.contains(first) {
    command = first
    positionals = Array(parsedPositionals.dropFirst())
} else {
    command = "handoff"
    positionals = parsedPositionals
}
let options = parsedOptions

let allowedOptions: Set<String>
let expectedPositionalCount: Int
switch command {
case "handoff":
    allowedOptions = ["--login-id"]
    expectedPositionalCount = 1
case "volume-up", "volume-down":
    allowedOptions = ["--step"]
    expectedPositionalCount = 1
case "volume-set":
    allowedOptions = ["--volume"]
    expectedPositionalCount = 1
case "playback-start":
    allowedOptions = ["--spotify-uri", "--spotify-device-name", "--spotify-device-type"]
    expectedPositionalCount = 0
case "playback-command", "sonos-status", "volume-status", "volume-mute", "volume-mute-on", "volume-mute-off", "volume-zero-muted":
    allowedOptions = []
    expectedPositionalCount = 1
case "playback-status", "playback-devices":
    allowedOptions = []
    expectedPositionalCount = 0
default:
    fatalError("Unknown command: \(command)")
}

if let invalidOption = options.keys.filter({ !allowedOptions.contains($0) }).sorted().first {
    fatalError("\(invalidOption) is not valid for \(command)")
}
if command == "volume-set", options["--volume"] == nil {
    fatalError("volume-set requires --volume 0...100")
}
guard positionals.count == expectedPositionalCount else {
    fatalError("\(command) expects \(expectedPositionalCount) positional argument(s); got \(positionals.count)")
}

let service = SpotifyConnectHandoffService(loginID: options["--login-id"])

switch command {
case "handoff":
    switch await service.transfer(toRoomName: roomNameArgument(), verification: .full) {
    case .success:
        print("sonos_transport=playing")
        print("handoff=ok")
    case .failure(_, let message):
        fatalError(message)
    }
case "volume-up":
    let volume = try await service.volumeUp(roomName: roomNameArgument(), step: volumeStep())
    print("volume=\(volume)")
    print("volume-up=ok")
case "volume-down":
    let volume = try await service.volumeDown(roomName: roomNameArgument(), step: volumeStep())
    print("volume=\(volume)")
    print("volume-down=ok")
case "volume-set":
    let volume = try await service.setVolume(roomName: roomNameArgument(), volume: desiredVolume())
    print("volume=\(volume)")
    print("volume-set=ok")
case "volume-status":
    let status = try await service.volumeStatus(roomName: roomNameArgument())
    print("volume=\(status.volume)")
    print("output_fixed=\(status.outputFixed)")
    print("muted=\(status.muted)")
    print("volume-status=ok")
case "volume-mute":
    let muted = try await service.toggleMute(roomName: roomNameArgument())
    print("muted=\(muted)")
    print("volume-mute=ok")
case "volume-mute-on":
    let muted = try await service.setMute(roomName: roomNameArgument(), muted: true)
    print("muted=\(muted)")
    print("volume-mute-on=ok")
case "volume-mute-off":
    let muted = try await service.setMute(roomName: roomNameArgument(), muted: false)
    print("muted=\(muted)")
    print("volume-mute-off=ok")
case "volume-zero-muted":
    let roomName = roomNameArgument()
    let volume = try await service.setVolume(roomName: roomName, volume: 0)
    let muted = try await service.setMute(roomName: roomName, muted: true)
    print("volume=\(volume)")
    print("muted=\(muted)")
    print("volume-zero-muted=ok")
case "playback-status":
    guard let status = try await service.activePlaybackDeviceStatus() else {
        fatalError("Spotify has no active playback")
    }
    print("spotify_device=\(status.deviceName) type=\(status.type) restricted=\(status.isRestricted)")
    if let volume = status.volumePercent {
        print("spotify_device_volume=\(volume)")
    }
    print("spotify_playing=\(status.isPlaying)")
    if let itemName = status.itemName, let itemURI = status.itemURI {
        print("spotify_item=\(itemName)")
        print("spotify_uri=\(itemURI)")
    }
    print("playback-status=ok")
case "playback-devices":
    let devices = try await service.availablePlaybackDevices()
    print("spotify_devices_count=\(devices.count)")
    for device in devices {
        print("spotify_device name=\(device.name) type=\(device.type) active=\(device.isActive) restricted=\(device.isRestricted)")
    }
    print("playback-devices=ok")
case "playback-start":
    try await service.startActivePlayback(
        spotifyURI: options["--spotify-uri"],
        deviceName: options["--spotify-device-name"],
        deviceType: options["--spotify-device-type"]
    )
    print("playback-start=ok")
case "playback-command":
    let playbackCommand = spotifyPlaybackCommandArgument()
    try await service.sendActivePlaybackCommand(playbackCommand)
    print("spotify_playback_command=\(playbackCommand.rawValue)")
    print("playback-command=ok")
case "sonos-status":
    let status = try await service.sonosTransportStatus(roomName: roomNameArgument())
    print("current_uri=\(status.currentURI)")
    print("transport_state=\(status.transportState)")
    print("sonos-status=ok")
default:
    fatalError("Unknown command: \(command)")
}

func printUsage() {
    print(
        """
        Usage:
          sonos-handoff-port [handoff] [room] [--login-id LOGIN_ID]
          sonos-handoff-port playback-status
          sonos-handoff-port playback-devices
          sonos-handoff-port playback-start [--spotify-uri URI] [--spotify-device-name NAME] [--spotify-device-type TYPE]
          sonos-handoff-port playback-command play|pause|next|previous
          sonos-handoff-port sonos-status [room]
          sonos-handoff-port volume-status [room]
          sonos-handoff-port volume-up [room] [--step 5...25]
          sonos-handoff-port volume-down [room] [--step 5...25]
          sonos-handoff-port volume-set [room] --volume 0...100
          sonos-handoff-port volume-mute [room]
          sonos-handoff-port volume-mute-on [room]
          sonos-handoff-port volume-mute-off [room]
          sonos-handoff-port volume-zero-muted [room]
        """
    )
}

func volumeStep() -> Int {
    let raw = options["--step"] ?? "5"
    guard let step = Int(raw), (5 ... 25).contains(step) else {
        fatalError("--step must be an integer from 5 to 25")
    }

    return step
}

func desiredVolume() -> Int {
    guard let raw = options["--volume"], let volume = Int(raw), (0 ... 100).contains(volume) else {
        fatalError("volume-set requires --volume 0...100")
    }

    return volume
}

func roomNameArgument() -> String {
    guard let roomName = positionals.first?.trimmingCharacters(in: .whitespacesAndNewlines), !roomName.isEmpty else {
        fatalError("\(command) requires a Sonos room name")
    }

    return roomName
}

func spotifyPlaybackCommandArgument() -> SpotifyPlaybackCommand {
    guard let rawCommand = positionals.first?.trimmingCharacters(in: .whitespacesAndNewlines),
          let command = SpotifyPlaybackCommand(rawValue: rawCommand),
          command != .playPause
    else {
        fatalError("playback-command requires play, pause, next, or previous")
    }

    return command
}
