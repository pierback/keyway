import Foundation

public enum SpotifyScopes {
    public static let playbackRead = "user-read-playback-state"
    public static let playbackModify = "user-modify-playback-state"
    public static let userReadPrivate = "user-read-private"
    public static let required = [playbackRead, playbackModify, userReadPrivate]
}
