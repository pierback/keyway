import SonosHandoffCore
import SwiftUI

@MainActor
struct MenuBarOutputSection: View {
    private static let accentColor = Color(nsColor: .controlAccentColor)
    private static let rowHeight: CGFloat = 36
    private static let iconSize: CGFloat = 28
    private static let trailingControlSize: CGFloat = 22

    @ObservedObject var playback: PlaybackSyncController
    let spotifySource: MediaRemoteTarget?
    let groupEditing: Bool

    @State private var forceGroupEditing = false

    private var canToggleGroupEditing: Bool {
        !playback.outputRows.isEmpty || !playback.groupEditController.groupEditRows.isEmpty
    }

    private var groupEditingActive: Bool {
        canToggleGroupEditing && (groupEditing || forceGroupEditing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(groupEditingActive ? "Group" : "Speakers")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if canToggleGroupEditing {
                    Button(groupEditingActive ? "Done" : "Edit Group") {
                        withAnimation(MenuBarMotion.modeSwitch) {
                            forceGroupEditing.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .help("Hold ⌥ to edit the group temporarily")
                    .accessibilityIdentifier("toggle-group-editing")
                    .accessibilityLabel(groupEditingActive ? "Hide Grouping" : "Show Grouping")
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            .contentTransition(.opacity)
            .animation(MenuBarMotion.modeSwitch, value: groupEditingActive)

            rows
                .animation(MenuBarMotion.modeSwitch, value: groupEditingActive)
                .animation(MenuBarMotion.rowUpdate, value: playback.outputRows)
                .animation(MenuBarMotion.rowUpdate, value: playback.groupEditController.groupEditRows)

            if let menuMessage = playback.menuMessage {
                Text(menuMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 5)
                    .padding(.bottom, 8)
                    .transition(MenuBarMotion.statusTransition)
            }
        }
        .onDisappear {
            forceGroupEditing = false
        }
        .animation(MenuBarMotion.rowUpdate, value: playback.menuMessage)
        .animation(MenuBarMotion.rowUpdate, value: playback.spotifyAuthRequired)
    }

    @ViewBuilder
    private var rows: some View {
        if groupEditingActive {
            groupRows
                .transition(MenuBarMotion.modeTransition)
        } else {
            outputRows
                .transition(MenuBarMotion.modeTransition)
        }
    }

    @ViewBuilder
    private var groupRows: some View {
        if playback.groupEditController.groupEditRows.isEmpty {
            emptyGroupRow
        } else {
            ForEach(playback.groupEditController.groupEditRows) { row in
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
            ForEach(playback.outputRows) { row in
                outputRowStack(for: row)
                    .transition(MenuBarMotion.rowTransition)
            }
        }
    }

    private var emptyOutputRow: some View {
        return HStack(spacing: 9) {
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
        return HStack(spacing: 9) {
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

    private func outputRowStack(for row: PlaybackOutputRow) -> some View {
        let selected = row.contains(roomName: playback.selectedRoomName)
        let mixerExpanded = isMixerExpanded(row, selected: selected)

        return VStack(alignment: .leading, spacing: 0) {
            outputRow(for: row, selected: selected, mixerExpanded: mixerExpanded)
                .task(id: mixerExpanded ? row.id : "collapsed-\(row.id)") {
                    if mixerExpanded {
                        playback.memberVolumeController.loadMemberVolumes(for: row)
                    }
                }

            if selected {
                MenuBarVolumeControl(playback: playback)
                    .padding(.leading, Self.iconSize + 11)
                    .padding(.trailing, 4)
                    .padding(.bottom, 6)
            }

            if mixerExpanded {
                ForEach(playback.memberVolumeController.memberVolumeRows.filter { $0.groupID == row.id }) { memberRow in
                    memberVolumeRow(memberRow)
                        .transition(MenuBarMotion.rowTransition)
                }
            }
        }
        .animation(MenuBarMotion.rowUpdate, value: mixerExpanded)
        .animation(MenuBarMotion.rowUpdate, value: playback.memberVolumeController.memberVolumeRows)
    }

    private func outputRow(for row: PlaybackOutputRow, selected: Bool, mixerExpanded: Bool) -> some View {
        let loading = row.coordinator.roomName == playback.loadingRoomName
        let groupJoinRow = directGroupJoinRow(for: row, selected: selected)
        let grouping = groupJoinRow.map { $0.displayName == playback.groupLoadingRoomName } ?? false
        let subtitle = loading ? "Transferring..." : grouping ? "Adding..." : nil

        return HStack(spacing: 0) {
            Button {
                playback.selectSpeaker(row: row)
                if let spotifySource, !playback.hasActiveSpotifyConnection(to: row) {
                    playback.transferSpotifyPlayback(source: spotifySource, to: row)
                }
            } label: {
                HStack(spacing: 11) {
                    ZStack {
                        Circle()
                            .fill(outputIconBackground(selected: selected))

                        Image(systemName: outputIconName(for: row))
                            .font(.system(size: 13, weight: .medium))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(outputIconForeground(selected: selected))
                    }
                    .frame(width: Self.iconSize, height: Self.iconSize)

                    rowTitle(row.displayName, subtitle: subtitle, dimmed: loading)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(playback.loadingRoomName != nil || playback.groupLoadingRoomName != nil || playback.volumeState.isBusy)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("select-speaker-\(row.coordinator.roomName)")
            .accessibilityLabel("Select speaker \(row.displayName)")
            .accessibilityValue(selected ? "Selected" : "")
            .accessibilityHint(spotifySource == nil ? "Shows volume and grouping controls for \(row.displayName)" : "Plays Spotify on \(row.displayName)")

            HStack(spacing: 0) {
                if loading || selected {
                    rowStatus(loading: loading, selected: selected)
                } else if let groupJoinRow {
                    groupJoinButton(for: groupJoinRow, loading: grouping)
                } else {
                    trailingControlPlaceholder()
                }

                if selected && row.isGroup {
                    Button {
                        playback.memberVolumeController.toggleMixer(for: row)
                    } label: {
                        Image(systemName: mixerExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.secondary.opacity(0.85))
                            .frame(width: Self.trailingControlSize, height: Self.rowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(playback.loadingRoomName != nil || playback.groupLoadingRoomName != nil)
                    .accessibilityIdentifier("mixer-toggle-\(row.coordinator.roomName)")
                    .accessibilityLabel(mixerExpanded ? "Collapse \(row.displayName) mixer" : "Expand \(row.displayName) mixer")
                } else {
                    trailingControlPlaceholder()
                }
            }
            .frame(width: Self.trailingControlSize * 2, height: Self.rowHeight)
        }
        .contentShape(Rectangle())
        .animation(MenuBarMotion.selection, value: selected)
        .animation(MenuBarMotion.selection, value: loading)
        .animation(MenuBarMotion.selection, value: grouping)
        .padding(.horizontal, 4)
    }

    private func trailingControlPlaceholder() -> some View {
        Color.clear
            .frame(width: Self.trailingControlSize, height: Self.rowHeight)
    }

    private func groupJoinButton(for row: PlaybackGroupEditRow, loading: Bool) -> some View {
        Button {
            playback.toggleGroupMembership(row)
        } label: {
            ZStack {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.56)
                        .transition(MenuBarMotion.statusTransition)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .transition(MenuBarMotion.statusTransition)
                }
            }
            .frame(width: Self.trailingControlSize, height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(playback.loadingRoomName != nil || playback.groupLoadingRoomName != nil || !row.canToggle)
        .accessibilityIdentifier("group-add-\(row.displayName)")
        .accessibilityLabel("Add \(row.displayName) to current group")
    }

    private func memberVolumeRow(_ row: PlaybackMemberVolumeRow) -> some View {
        let removalRow = directGroupRemovalRow(for: row)
        let groupLoading = removalRow.map { $0.displayName == playback.groupLoadingRoomName } ?? false

        return HStack(spacing: 9) {
            Image(systemName: "hifispeaker")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.secondary.opacity(0.82))
                .frame(width: 14, height: 18)

            Text(row.speaker.roomName)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.82))
                .lineLimit(1)
                .frame(width: 74, alignment: .leading)

            MemberVolumeSlider(playback: playback, row: row)
                .opacity(row.state.hasStatus && !row.state.outputFixed ? 1 : 0.48)
                .disabled(!row.state.hasStatus || row.state.outputFixed || row.state.isBusy)

            if row.state.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.52)
                    .frame(width: 25, height: 18)
            } else {
                Text(row.state.hasStatus ? "\(row.state.roundedValue)%" : "--")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 25, alignment: .trailing)
            }

            if let removalRow {
                groupRemovalButton(for: removalRow, loading: groupLoading)
            } else {
                Color.clear
                    .frame(width: Self.trailingControlSize, height: 28)
            }
        }
        .frame(height: 28)
        .padding(.leading, Self.iconSize + 15)
        .padding(.trailing, 4)
    }

    private func groupRemovalButton(for row: PlaybackGroupEditRow, loading: Bool) -> some View {
        Button {
            playback.toggleGroupMembership(row)
        } label: {
            ZStack {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.52)
                        .transition(MenuBarMotion.statusTransition)
                } else {
                    Image(systemName: "minus")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.42))
                        .transition(MenuBarMotion.statusTransition)
                }
            }
            .frame(width: Self.trailingControlSize, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(playback.loadingRoomName != nil || playback.groupLoadingRoomName != nil || !row.canToggle)
        .accessibilityIdentifier("group-remove-\(row.displayName)")
        .accessibilityLabel(groupAccessibilityLabel(for: row))
    }

    private func groupEditRow(for row: PlaybackGroupEditRow) -> some View {
        let loading = row.displayName == playback.groupLoadingRoomName
        let disabled = playback.groupLoadingRoomName != nil || playback.loadingRoomName != nil || !row.canToggle
        let subtitle = groupRowSubtitle(for: row, loading: loading)

        return Button {
            playback.toggleGroupMembership(row)
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(row.isInGroup ? Self.accentColor : Color.primary.opacity(0.08))

                    Image(systemName: groupIconName(for: row))
                        .font(.system(size: 13, weight: .medium))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(groupIconForeground(for: row))
                }
                .frame(width: Self.iconSize, height: Self.iconSize)

                rowTitle(row.displayName, subtitle: subtitle, dimmed: loading)

                Spacer(minLength: 0)

                groupRowStatus(for: row, loading: loading)
            }
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .animation(MenuBarMotion.selection, value: row.isInGroup)
            .animation(MenuBarMotion.selection, value: loading)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .padding(.horizontal, 4)
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
        .frame(width: Self.trailingControlSize, height: Self.rowHeight)
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
        .frame(width: Self.trailingControlSize, height: Self.rowHeight)
    }

    private func rowTitle(_ title: String, subtitle: String?, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(dimmed ? 0.6 : 1))
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
        selected ? Self.accentColor : Color.primary.opacity(0.08)
    }

    private func outputIconForeground(selected: Bool) -> Color {
        selected ? Color.white : Color.secondary.opacity(0.85)
    }

    private func isMixerExpanded(_ row: PlaybackOutputRow, selected: Bool) -> Bool {
        guard row.isGroup, selected else {
            return false
        }

        return playback.memberVolumeController.isMixerPinned(for: row)
    }

    private func directGroupJoinRow(for row: PlaybackOutputRow, selected: Bool) -> PlaybackGroupEditRow? {
        guard !selected else {
            return nil
        }

        return playback.groupEditController.groupEditRows.first { editRow in
            (editRow.id == row.id || editRow.speaker.id == row.coordinator.id)
                && editRow.canToggle
                && (editRow.membership == .available || editRow.membership == .availableGroup)
        }
    }

    private func directGroupRemovalRow(for row: PlaybackMemberVolumeRow) -> PlaybackGroupEditRow? {
        playback.groupEditController.groupEditRows.first { editRow in
            editRow.speaker.id == row.speaker.id
                && editRow.canToggle
                && (editRow.membership == .member || editRow.membership == .coordinator)
        }
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

        return row.isInGroup ? Color.white : Color.secondary.opacity(0.85)
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

@MainActor
private struct MemberVolumeSlider: View {
    @ObservedObject var playback: PlaybackSyncController
    let row: PlaybackMemberVolumeRow

    var body: some View {
        GeometryReader { proxy in
            track(width: proxy.size.width)
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .accessibilityLabel("\(row.speaker.roomName) volume")
        .accessibilityIdentifier("member-volume-\(row.speaker.roomName)")
        .accessibilityValue(row.state.hasStatus ? "\(row.state.roundedValue) percent" : "Unknown")
    }

    private func track(width: CGFloat) -> some View {
        let trackWidth = max(width, 1)
        let clampedVolume = min(max(row.state.value, 0), 100)
        let progress = CGFloat(clampedVolume / 100)
        let knobSize: CGFloat = 12
        let knobOffset = min(max((trackWidth * progress) - (knobSize / 2), 0), max(trackWidth - knobSize, 0))

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.15))
                .frame(height: 3)

            Capsule()
                .fill(Color.primary.opacity(0.7))
                .frame(width: max(trackWidth * progress, knobSize / 2), height: 3)

            Circle()
                .fill(Color.white)
                .frame(width: knobSize, height: knobSize)
                .offset(x: knobOffset)
                .shadow(color: .black.opacity(0.2), radius: 0.6, y: 0.4)
        }
        .frame(height: 18)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard row.state.hasStatus, !row.state.outputFixed, !row.state.isBusy else {
                        return
                    }
                    playback.memberVolumeController.setMemberVolumeFromSlider(
                        rowID: row.id,
                        locationX: value.location.x,
                        width: trackWidth
                    )
                }
                .onEnded { value in
                    guard row.state.hasStatus, !row.state.outputFixed, !row.state.isBusy else {
                        return
                    }
                    playback.memberVolumeController.setMemberVolumeFromSlider(
                        rowID: row.id,
                        locationX: value.location.x,
                        width: trackWidth
                    )
                    playback.commitMemberVolume(rowID: row.id)
                }
        )
    }
}
