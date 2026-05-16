import SwiftUI

@MainActor
struct MenuBarVolumeControl: View {
    @ObservedObject var playback: PlaybackSyncController

    var body: some View {
        HStack(spacing: 5) {
            Button {
                playback.toggleMute()
            } label: {
                Image(systemName: playback.volumeState.muted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 11, weight: .regular))
                    .frame(width: 14, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary.opacity(0.9))
            .opacity(playback.canControlVolume ? 1 : 0.45)
            .disabled(!playback.canControlVolume)

            NativeVolumeSlider(playback: playback)
                .disabled(!playback.canControlVolume || playback.volumeState.outputFixed)
                .opacity(playback.canControlVolume && !playback.volumeState.outputFixed ? 1 : 0.45)

            Button {
                playback.adjustVolume(.up)
            } label: {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 21, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary.opacity(0.9))
            .opacity(playback.canControlVolume ? 1 : 0.45)
            .disabled(!playback.canControlVolume || playback.volumeState.outputFixed)
        }
        .frame(height: 18)
        .padding(.horizontal, 9)
        .padding(.bottom, 7)
    }
}

@MainActor
private struct NativeVolumeSlider: View {
    @ObservedObject var playback: PlaybackSyncController

    var body: some View {
        GeometryReader { proxy in
            track(width: proxy.size.width)
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .accessibilityLabel("Volume")
        .accessibilityIdentifier("sonos-volume-slider")
        .accessibilityValue("\(playback.volumeState.roundedValue) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                playback.adjustVolume(.up)
            case .decrement:
                playback.adjustVolume(.down)
            default:
                break
            }
        }
    }

    private func track(width: CGFloat) -> some View {
        let trackWidth = max(width, 1)
        let clampedVolume = min(max(playback.volumeState.value, 0), 100)
        let progress = CGFloat(clampedVolume / 100)
        let knobSize: CGFloat = 17
        let knobOffset = min(max((trackWidth * progress) - (knobSize / 2), 0), max(trackWidth - knobSize, 0))

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(height: 4)

            Capsule()
                .fill(Color.white.opacity(0.92))
                .frame(width: max(trackWidth * progress, knobSize / 2), height: 4)

            Circle()
                .fill(Color.white.opacity(0.96))
                .frame(width: knobSize, height: knobSize)
                .offset(x: knobOffset)
                .shadow(color: .black.opacity(0.22), radius: 0.75, y: 0.5)
        }
        .frame(height: 18)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard playback.canControlVolume, !playback.volumeState.outputFixed else {
                        return
                    }
                    playback.setSliderEditing(true)
                    playback.setVolumeFromSlider(locationX: value.location.x, width: trackWidth)
                    playback.commitSliderVolumeDebounced()
                }
                .onEnded { value in
                    defer {
                        playback.setSliderEditing(false)
                    }

                    guard playback.canControlVolume, !playback.volumeState.outputFixed else {
                        return
                    }
                    playback.setVolumeFromSlider(locationX: value.location.x, width: trackWidth)
                    playback.commitSliderVolumeImmediately()
                }
        )
    }
}
