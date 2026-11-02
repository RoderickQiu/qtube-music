import Foundation
import Observation
import QTCore

/// What the sleep timer is set to: a length in minutes, or the end of the song that's playing.
public enum QTSleepTimerChoice: Hashable, Sendable {
    case minutes(Int)
    case endOfSong

    /// The lengths every Sleep Timer menu offers (Controls, the Dock, the player bar's button).
    public static let presetMinutes = [15, 30, 45, 60, 90]

    /// The smallest preset at least `seconds` long (the longest one past 90 min): which item a timer started with a
    /// custom remaining time (`-qt.player.sleepTimer`) checks.
    public static func preset(covering seconds: TimeInterval) -> QTSleepTimerChoice {
        .minutes(presetMinutes.first { TimeInterval($0 * 60) >= seconds } ?? presetMinutes[presetMinutes.count - 1])
    }
}

/// The sleep timer. A length counts down on the wall clock whether or not anything plays (like the Clock app's timer),
/// so a Mac that slept meanwhile catches up. Over its last `fadeDuration` seconds the volume fades out through the
/// queue (`QTQueueController.setVolume` → the playing engine's own volume: web and native alike, and an engine swap
/// mid-fade carries on); then playback pauses — which lets go of the idle-sleep assertion
/// (`QTQueueController.updatePlaybackActivity` holds it only while playing) —, the volume goes back to where it was so
/// the next Play isn't silent, and the timer turns off.
///
/// End of Song is the queue's `stopsAtEndOfItem`: the song that's playing when it ends (after a Next, the new one)
/// stops there, and the queue moves on to the next song cued, not playing. It doesn't fade: songs end by themselves.
///
/// The listener stays in charge: pausing during the fade ends the timer (the volume comes back); setting the volume
/// during the fade ends it at their volume (`listenerChangedVolume`); Next and Previous don't touch it. Nothing is
/// saved — quitting turns it off, and the volume isn't saved either, so a fade cut short by quitting leaves nothing.
@MainActor
@Observable
public final class QTSleepTimer {
    /// The fade at the end of a length (inside it: "15 minutes" stops 15 minutes from now).
    public static let fadeDuration: TimeInterval = 30
    /// Volume steps during the fade.
    static let fadeStep: TimeInterval = 0.5
    /// Longest wait between checks while counting down to the fade.
    static let countdownStep: TimeInterval = 30

    /// nil = off.
    public private(set) var choice: QTSleepTimerChoice?
    /// When playback stops, in `now()` seconds; nil for End of Song and while off.
    public private(set) var deadline: TimeInterval?
    /// The volume is going down.
    public private(set) var isFading = false

    @ObservationIgnored private let playback: QTQueueController
    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private let schedulesTicks: Bool
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// The listener's volume when the fade began; put back once playback has paused.
    @ObservationIgnored private(set) var volumeBeforeFade: Double?

    /// - Parameters:
    ///   - now: the clock (seconds; wall clock by default, so time asleep counts). Tests inject a manual one.
    ///   - schedulesTicks: false = the timer moves only when `tick()` is called (tests on a manual clock).
    public init(playback: QTQueueController,
                now: @escaping @MainActor () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
                schedulesTicks: Bool = true) {
        self.playback = playback
        self.now = now
        self.schedulesTicks = schedulesTicks
        playback.onStoppedAtEndOfItem = { [weak self] in self?.reset() }
    }

    public var isActive: Bool { choice != nil }

    /// Seconds until playback stops (0 at the end), or nil (off, End of Song).
    public var remaining: TimeInterval? { deadline.map { max(0, $0 - now()) } }

    /// Starts (or restarts, from now) the timer.
    public func start(_ choice: QTSleepTimerChoice) {
        start(choice, remaining: nil)
    }

    /// `remaining` overrides a length's own (the DEBUG launch argument `-qt.player.sleepTimer <s>`).
    public func start(_ choice: QTSleepTimerChoice, remaining: TimeInterval?) {
        endFade(restoringVolume: true)
        self.choice = choice
        switch choice {
        case .minutes(let minutes):
            deadline = now() + max(0, remaining ?? TimeInterval(minutes * 60))
            playback.stopsAtEndOfItem = false
        case .endOfSong:
            deadline = nil
            tickTask?.cancel()
            tickTask = nil
            playback.stopsAtEndOfItem = true
        }
        tick()
    }

    /// Turn Off: the volume comes back if it was fading; playback carries on.
    public func turnOff() {
        endFade(restoringVolume: true)
        reset()
    }

    /// The listener set the volume (the slider, ⌘↑/⌘↓, AppleScript). During the fade that's someone awake: the timer
    /// turns off and their volume stays.
    public func listenerChangedVolume() {
        guard isFading else { return }
        endFade(restoringVolume: false)
        reset()
    }

    /// Checks the clock: fades, stops, or schedules the next check. The timer's own ticks call it; tests call it.
    public func tick() {
        guard let deadline else { return }
        let left = deadline - now()
        guard left > 0 else { return finish() }
        if left <= Self.fadeDuration {
            if playback.wantsPlayback {
                fade(remaining: left)
            } else if isFading {
                // Paused during the fade: the listener stopped the music themselves.
                endFade(restoringVolume: true)
                return reset()
            }
            scheduleTick(after: min(left, Self.fadeStep))
        } else {
            scheduleTick(after: min(left - Self.fadeDuration, Self.countdownStep))
        }
    }

    /// The fade's volume factor with `remaining` seconds of it left: 1 at its start, 0 at the end. Squared, so the
    /// loudness falls about evenly instead of most of it going in the last seconds.
    public static func fadeGain(remaining: TimeInterval) -> Double {
        let p = min(1, max(0, remaining / fadeDuration))
        return p * p
    }

    // MARK: Private

    private func fade(remaining left: TimeInterval) {
        let base: Double
        if let v = volumeBeforeFade {
            base = v
        } else {
            base = playback.engine.state.volume
            volumeBeforeFade = base
            isFading = true
        }
        playback.setVolume(base * Self.fadeGain(remaining: left))
    }

    /// Time's up: pause (if anything plays or is about to), then the volume comes back for the next Play.
    private func finish() {
        if playback.wantsPlayback || playback.engine.state.isPlaying { playback.pause() }
        endFade(restoringVolume: true)
        reset()
    }

    private func endFade(restoringVolume: Bool) {
        isFading = false
        guard let base = volumeBeforeFade else { return }
        volumeBeforeFade = nil
        if restoringVolume { playback.setVolume(base) }
    }

    private func reset() {
        choice = nil
        deadline = nil
        isFading = false
        playback.stopsAtEndOfItem = false
        tickTask?.cancel()
        tickTask = nil
    }

    private func scheduleTick(after seconds: TimeInterval) {
        tickTask?.cancel()
        tickTask = nil
        guard schedulesTicks else { return }
        tickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, seconds)))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }
}
