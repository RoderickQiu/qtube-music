import AppKit
import Foundation
import IOKit.ps
import Observation

/// Low Power Mode and battery state, so the Stage can step its motion down.
/// - Low Power Mode: no drift / Ken Burns, visualizer at 30 fps.
/// - On battery: the visualizer holds a still frame by default (spec §4.1 "off on battery by default").
@MainActor
@Observable
final class QTStagePowerMonitor {
    static let shared = QTStagePowerMonitor()

    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var isOnBattery = QTStagePowerMonitor.readOnBattery()

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var poll: Task<Void, Never>?

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        // Power-source changes are rare; a slow poll avoids a CF run-loop source.
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.refresh()
            }
        }
    }

    func refresh() {
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        if low != isLowPowerMode { isLowPowerMode = low }
        let battery = Self.readOnBattery()
        if battery != isOnBattery { isOnBattery = battery }
    }

    private static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

/// How much the Stage may move, combining Reduce Motion, Low Power Mode and play state.
struct QTStageMotionPolicy: Equatable {
    var reduceMotion: Bool
    var lowPower: Bool
    var onBattery: Bool
    /// `-qt.stage.visualizerOnBattery YES` (or the user default of the same name) keeps it animating on battery.
    var visualizerOnBattery: Bool

    /// Spinning record.
    var allowsSpin: Bool { !reduceMotion }
    /// Slow background drift / Ken Burns.
    var allowsAmbientDrift: Bool { !reduceMotion && !lowPower }
    /// Visualizer animates (otherwise a still frame).
    var allowsVisualizerAnimation: Bool { !(onBattery && !visualizerOnBattery) }
    var visualizerFPS: Int { lowPower || reduceMotion ? 30 : 60 }
}
