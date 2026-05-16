import SonosHandoffCore
import SwiftUI

@MainActor
struct MenuBarOutputSection: View {
    @ObservedObject var playback: PlaybackSyncController
    let openSpotifySettings: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Output")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if playback.speakers.isEmpty {
                emptyOutputRow
            } else {
                ForEach(playback.speakers) { speaker in
                    outputRow(for: speaker)
                }
            }

            if let menuMessage = playback.menuMessage {
                Text(menuMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.top, 5)
            }

            if playback.spotifyAuthRequired {
                Button(action: openSpotifySettings) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .frame(width: 16, height: 16)

                        Text("Sign In to Spotify...")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.9))

                        Spacer(minLength: 0)
                    }
                    .frame(height: 29)
                    .padding(.horizontal, 12)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.045))
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }
        }
    }

    private var emptyOutputRow: some View {
        HStack(spacing: 9) {
            if playback.isRefreshingOutputs {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.56)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "hifispeaker")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }

            Text(playback.isRefreshingOutputs ? "Searching..." : "No Sonos speakers found")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .padding(.horizontal, 10)
    }

    private func outputRow(for speaker: SonosSpeaker) -> some View {
        let selected = speaker.roomName == playback.selectedRoomName
        let loading = speaker.roomName == playback.loadingRoomName

        return Button {
            playback.transfer(to: speaker)
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(outputIconBackground(selected: selected))

                    Image(systemName: outputIconName(for: speaker))
                        .font(.system(size: 12, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(outputIconForeground(selected: selected))
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 0) {
                    Text(speaker.roomName)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if loading {
                        Text("Transferring...")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.56)
                        .frame(width: 18, height: 18)
                } else if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .frame(width: 18, height: 18)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.045 : 0))
            }
        }
        .buttonStyle(.plain)
        .disabled(playback.loadingRoomName != nil || playback.volumeState.isBusy)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transfer-to-\(speaker.roomName)")
        .accessibilityLabel("Transfer to \(speaker.roomName)")
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityHint("Hands off Spotify playback to \(speaker.roomName)")
    }

    private func outputIconName(for speaker: SonosSpeaker) -> String {
        switch speaker.roomName.lowercased() {
        case "port":
            return "hifispeaker"
        default:
            return "hifispeaker"
        }
    }

    private func outputIconBackground(selected: Bool) -> Color {
        selected ? Color.white.opacity(0.115) : Color.white.opacity(0.075)
    }

    private func outputIconForeground(selected: Bool) -> Color {
        selected ? Color.white.opacity(0.95) : Color.secondary.opacity(0.85)
    }
}
