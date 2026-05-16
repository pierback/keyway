import SonosHandoffCore
import SwiftUI

@MainActor
struct MenuBarOutputSection: View {
    @ObservedObject var playback: PlaybackSyncController
    let groupEditing: Bool
    let openSpotifySettings: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(groupEditing ? "Group" : "Output")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if groupEditing, !playback.groupEditRows.isEmpty {
                ForEach(playback.groupEditRows) { row in
                    groupEditRow(for: row)
                }
            } else if playback.outputRows.isEmpty {
                emptyOutputRow
            } else {
                if let suggestion = playback.groupSuggestion {
                    groupSuggestionRow(suggestion)
                }

                ForEach(playback.outputRows) { row in
                    outputRow(for: row)
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

    private func outputRow(for row: PlaybackOutputRow) -> some View {
        let selected = row.contains(roomName: playback.selectedRoomName)
        let loading = row.coordinator.roomName == playback.loadingRoomName

        return Button {
            playback.transfer(to: row)
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(outputIconBackground(selected: selected))

                    Image(systemName: outputIconName(for: row))
                        .font(.system(size: 12, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(outputIconForeground(selected: selected))
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 0) {
                    Text(row.displayName)
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
        .disabled(playback.loadingRoomName != nil || playback.groupLoadingRoomName != nil || playback.volumeState.isBusy)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transfer-to-\(row.coordinator.roomName)")
        .accessibilityLabel("Transfer to \(row.displayName)")
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityHint("Hands off Spotify playback to \(row.displayName)")
    }

    private func groupSuggestionRow(_ suggestion: PlaybackGroupSuggestion) -> some View {
        let loading = suggestion.speaker.roomName == playback.groupLoadingRoomName

        return Button {
            playback.acceptGroupSuggestion()
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.075))

                    Image(systemName: "hifispeaker.badge.plus")
                        .font(.system(size: 12, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Color.secondary.opacity(0.85))
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 0) {
                    Text(suggestion.speaker.roomName)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text("Add to \(suggestion.groupDisplayName)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.56)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .frame(width: 18, height: 18)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 33, alignment: .leading)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            }
        }
        .buttonStyle(.plain)
        .disabled(playback.groupLoadingRoomName != nil || playback.loadingRoomName != nil)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("group-suggestion-\(suggestion.speaker.roomName)")
        .accessibilityLabel("Add \(suggestion.speaker.roomName) to \(suggestion.groupDisplayName)")
    }

    private func groupEditRow(for row: PlaybackGroupEditRow) -> some View {
        let loading = row.speaker.roomName == playback.groupLoadingRoomName
        let disabled = playback.groupLoadingRoomName != nil || playback.loadingRoomName != nil

        return Button {
            playback.toggleGroupMembership(row)
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(row.isInGroup ? Color.white.opacity(0.115) : Color.white.opacity(0.075))

                    Image(systemName: groupIconName(for: row))
                        .font(.system(size: 12, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(row.isInGroup ? Color.white.opacity(0.95) : Color.secondary.opacity(0.85))
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 0) {
                    Text(row.speaker.roomName)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if row.isCoordinator {
                        Text("Coordinator")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                    } else if loading {
                        Text("Updating...")
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
                } else {
                    Image(systemName: row.isInGroup ? "checkmark" : "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(row.isInGroup ? 0.72 : 0.55))
                        .frame(width: 18, height: 18)
                }
            }
            .frame(maxWidth: .infinity, minHeight: row.isCoordinator ? 33 : 31, alignment: .leading)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(row.isInGroup ? 0.045 : 0))
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("group-toggle-\(row.speaker.roomName)")
        .accessibilityLabel(groupAccessibilityLabel(for: row))
    }

    private func outputIconName(for row: PlaybackOutputRow) -> String {
        if row.isGroup {
            return "hifispeaker.2"
        }

        switch row.coordinator.roomName.lowercased() {
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

    private func groupIconName(for row: PlaybackGroupEditRow) -> String {
        row.isCoordinator ? "hifispeaker.badge.plus" : "hifispeaker"
    }

    private func groupAccessibilityLabel(for row: PlaybackGroupEditRow) -> String {
        switch row.membership {
        case .available:
            return "Add \(row.speaker.roomName) to group"
        case .member:
            return "Remove \(row.speaker.roomName) from group"
        case .coordinator:
            return "Move coordinator and remove \(row.speaker.roomName) from group"
        }
    }
}
