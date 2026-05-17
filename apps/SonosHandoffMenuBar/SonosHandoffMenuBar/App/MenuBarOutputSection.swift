import SonosHandoffCore
import SwiftUI

@MainActor
struct MenuBarOutputSection: View {
    private static let accentColor = Color(nsColor: .controlAccentColor)
    private static let rowHeight: CGFloat = 32
    private static let suggestionRowHeight: CGFloat = 34
    private static let iconSize: CGFloat = 22

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
            .contentTransition(.opacity)
            .animation(MenuBarMotion.modeSwitch, value: groupEditing)

            rows
                .animation(MenuBarMotion.modeSwitch, value: groupEditing)
                .animation(MenuBarMotion.rowUpdate, value: playback.outputRows)
                .animation(MenuBarMotion.rowUpdate, value: playback.groupEditRows)
                .animation(MenuBarMotion.rowUpdate, value: playback.groupSuggestions)

            if let menuMessage = playback.menuMessage {
                Text(menuMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.top, 5)
                    .transition(MenuBarMotion.statusTransition)
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
                .transition(MenuBarMotion.statusTransition)
            }
        }
        .animation(MenuBarMotion.rowUpdate, value: playback.menuMessage)
        .animation(MenuBarMotion.rowUpdate, value: playback.spotifyAuthRequired)
    }

    @ViewBuilder
    private var rows: some View {
        if groupEditing {
            groupRows
                .transition(MenuBarMotion.modeTransition)
        } else {
            outputRows
                .transition(MenuBarMotion.modeTransition)
        }
    }

    @ViewBuilder
    private var groupRows: some View {
        if playback.groupEditRows.isEmpty {
            emptyGroupRow
        } else {
            ForEach(playback.groupEditRows) { row in
                groupEditRow(for: row)
                    .transition(MenuBarMotion.rowTransition)
            }
        }
    }

    @ViewBuilder
    private var outputRows: some View {
        if playback.outputRows.isEmpty {
            emptyOutputRow
        } else {
            ForEach(playback.groupSuggestions) { suggestion in
                groupSuggestionRow(suggestion)
                    .transition(MenuBarMotion.rowTransition)
            }

            ForEach(playback.outputRows) { row in
                outputRow(for: row)
                    .transition(MenuBarMotion.rowTransition)
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

    private var emptyGroupRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "hifispeaker.slash")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            Text("No active Sonos group")
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
        let subtitle = loading ? "Transferring..." : nil

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
                .frame(width: Self.iconSize, height: Self.iconSize)

                rowTitle(row.displayName, subtitle: subtitle, dimmed: loading)

                Spacer(minLength: 0)

                rowStatus(loading: loading, selected: selected)
            }
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Self.accentColor.opacity(0.11) : Color.clear)
            }
            .animation(MenuBarMotion.selection, value: selected)
            .animation(MenuBarMotion.selection, value: loading)
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

        return HStack(spacing: 0) {
            Button {
                playback.acceptGroupSuggestion(id: suggestion.id)
            } label: {
                HStack(spacing: 13) {
                    ZStack {
                        Circle()
                            .fill(Self.accentColor.opacity(0.18))

                        Image(systemName: "hifispeaker.badge.plus")
                            .font(.system(size: 12, weight: .regular))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(Self.accentColor.opacity(0.95))
                    }
                    .frame(width: Self.iconSize, height: Self.iconSize)

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
                }
                .frame(maxWidth: .infinity, minHeight: Self.suggestionRowHeight, alignment: .leading)
                .padding(.leading, 12)
            }
            .buttonStyle(.plain)
            .disabled(playback.groupLoadingRoomName != nil || playback.loadingRoomName != nil)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("group-suggestion-\(suggestion.speaker.roomName)")
            .accessibilityLabel("Add \(suggestion.speaker.roomName) to \(suggestion.groupDisplayName)")

            if loading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.56)
                    .frame(width: 26, height: 26)
            } else {
                Button {
                    playback.ignoreGroupSuggestion(id: suggestion.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.48))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(playback.groupLoadingRoomName != nil || playback.loadingRoomName != nil)
                .accessibilityIdentifier("ignore-group-suggestion-\(suggestion.speaker.roomName)")
                .accessibilityLabel("Ignore grouping suggestion for \(suggestion.speaker.roomName)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.trailing, 2)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.045))
        }
    }

    private func groupEditRow(for row: PlaybackGroupEditRow) -> some View {
        let loading = row.displayName == playback.groupLoadingRoomName
        let disabled = playback.groupLoadingRoomName != nil || playback.loadingRoomName != nil || !row.canToggle
        let subtitle = groupRowSubtitle(for: row, loading: loading)

        return Button {
            playback.toggleGroupMembership(row)
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(row.isInGroup ? Self.accentColor : Color.white.opacity(0.075))

                    Image(systemName: groupIconName(for: row))
                        .font(.system(size: 12, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(groupIconForeground(for: row))
                }
                .frame(width: Self.iconSize, height: Self.iconSize)

                rowTitle(row.displayName, subtitle: subtitle, dimmed: loading)

                Spacer(minLength: 0)

                groupRowStatus(for: row, loading: loading)
            }
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(row.isInGroup ? Self.accentColor.opacity(0.11) : Color.clear)
            }
            .animation(MenuBarMotion.selection, value: row.isInGroup)
            .animation(MenuBarMotion.selection, value: loading)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("group-toggle-\(row.displayName)")
        .accessibilityLabel(groupAccessibilityLabel(for: row))
    }

    @ViewBuilder
    private func rowStatus(loading: Bool, selected: Bool) -> some View {
        ZStack {
            if loading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.56)
                    .transition(MenuBarMotion.statusTransition)
            } else if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.accentColor.opacity(0.95))
                    .transition(MenuBarMotion.statusTransition)
            }
        }
        .frame(width: 18, height: 18)
    }

    @ViewBuilder
    private func groupRowStatus(for row: PlaybackGroupEditRow, loading: Bool) -> some View {
        ZStack {
            if loading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.56)
                    .transition(MenuBarMotion.statusTransition)
            } else {
                Image(systemName: row.isInGroup ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(groupStatusForeground(for: row))
                    .transition(MenuBarMotion.statusTransition)
            }
        }
        .frame(width: 18, height: 18)
    }

    private func rowTitle(_ title: String, subtitle: String?, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.primary.opacity(dimmed ? 0.72 : 0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(MenuBarMotion.statusTransition)
            }
        }
        .frame(height: Self.rowHeight, alignment: .center)
        .animation(MenuBarMotion.selection, value: subtitle)
    }

    private func groupRowSubtitle(for row: PlaybackGroupEditRow, loading: Bool) -> String? {
        if loading {
            return "Updating..."
        }

        if row.isCoordinator {
            return "Coordinator"
        }

        return nil
    }

    private func outputIconName(for row: PlaybackOutputRow) -> String {
        if row.isGroup {
            return "hifispeaker.2"
        }

        return "hifispeaker"
    }

    private func outputIconBackground(selected: Bool) -> Color {
        selected ? Self.accentColor : Color.white.opacity(0.075)
    }

    private func outputIconForeground(selected: Bool) -> Color {
        selected ? Color.white.opacity(0.96) : Color.secondary.opacity(0.85)
    }

    private func groupIconName(for row: PlaybackGroupEditRow) -> String {
        if row.isGroup {
            return "hifispeaker.2"
        }

        return row.isCoordinator ? "hifispeaker.badge.plus" : "hifispeaker"
    }

    private func groupIconForeground(for row: PlaybackGroupEditRow) -> Color {
        if !row.canToggle {
            return Color.secondary.opacity(0.55)
        }

        return row.isInGroup ? Color.white.opacity(0.96) : Color.secondary.opacity(0.85)
    }

    private func groupStatusForeground(for row: PlaybackGroupEditRow) -> Color {
        if !row.canToggle {
            return Color.secondary.opacity(0.45)
        }

        return row.isInGroup ? Self.accentColor.opacity(0.95) : Color.primary.opacity(0.55)
    }

    private func groupAccessibilityLabel(for row: PlaybackGroupEditRow) -> String {
        switch row.membership {
        case .available, .availableGroup:
            return "Add \(row.displayName) to group"
        case .member:
            return "Remove \(row.speaker.roomName) from group"
        case .coordinator:
            guard row.coordinatorRemovalAvailable else {
                return "\(row.speaker.roomName) is the coordinator"
            }
            return "Move coordinator and remove \(row.speaker.roomName) from group"
        }
    }
}
