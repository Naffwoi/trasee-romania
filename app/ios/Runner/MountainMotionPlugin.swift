import CoreMotion
import Flutter
import UIKit

/// Hardware CoreMotion (`CMMotionActivityManager`) + battery/Low-Power-Mode bridge
/// for Wanderer's 4-State Mountain Power Engine.
///
/// Uses `NSMotionUsageDescription` already declared in `Info.plist`. On iOS,
/// `CMMotionActivityManager` runs on the M-series motion coprocessor (< 0.2 mW)
/// and delivers immediate walking/running/cycling wake callbacks while the app
/// holds its low-power 3km CoreLocation background assertion.
public final class MountainMotionPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static let methodChannelName = "com.openwanderer.wanderer/mountain_motion"
  private static let eventChannelName = "com.openwanderer.wanderer/mountain_motion/events"

  private let activityManager = CMMotionActivityManager()
  private let motionQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "com.openwanderer.wanderer.mountain_motion"
    q.maxConcurrentOperationCount = 1
    q.qualityOfService = .utility
    return q
  }()

  private var eventSink: FlutterEventSink?
  private var monitoring = false
  private var armedForWake = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = MountainMotionPlugin()
    let methodChannel = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: registrar.messenger()
    )
    let eventChannel = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
    UIDevice.current.isBatteryMonitoringEnabled = true
  }

  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startStepMonitoring":
      armedForWake = false
      let ok = ensureActivityUpdatesStarted()
      result(ok)

    case "armStationaryWakeTrigger":
      armedForWake = true
      let ok = ensureActivityUpdatesStarted()
      result(ok)

    case "stop":
      stopInternal()
      result(true)

    case "getBatterySnapshot":
      result(readBatterySnapshot())

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func ensureActivityUpdatesStarted() -> Bool {
    guard CMMotionActivityManager.isActivityAvailable() else {
      return false
    }
    if monitoring {
      return true
    }
    monitoring = true
    activityManager.startActivityUpdates(to: motionQueue) { [weak self] activity in
      guard let self = self, let activity = activity else { return }
      let activeLocomotion = activity.walking || activity.running || activity.cycling
      let stationary = activity.stationary && !activeLocomotion
      if self.armedForWake && activeLocomotion && activity.confidence != .low {
        self.armedForWake = false
        self.emitOnMain([
          "kind": "step_wake",
          "stepBandVariance": 1.5,
          "isMovingHardware": true,
        ])
        return
      }
      self.emitOnMain([
        "kind": "motion_sample",
        "stepBandVariance": stationary ? 0.002 : (activeLocomotion ? 0.85 : 0.08),
        "isMovingHardware": !stationary,
      ])
    }
    return true
  }

  private func stopInternal() {
    if monitoring {
      activityManager.stopActivityUpdates()
      monitoring = false
    }
    armedForWake = false
  }

  private func readBatterySnapshot() -> [String: Any] {
    UIDevice.current.isBatteryMonitoringEnabled = true
    let rawLevel = UIDevice.current.batteryLevel
    let pct = rawLevel >= 0 ? Int((rawLevel * 100.0).rounded()) : 100
    let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    return [
      "batteryPercent": min(100, max(0, pct)),
      "osLowPowerMode": lowPower,
    ]
  }

  private func emitOnMain(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }
}
