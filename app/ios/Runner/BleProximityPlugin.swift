import Flutter
import UIKit
import CoreBluetooth

/// Zero-dependency native Dual-Role BLE transport for Wanderer ("SOS fără semnal" & "Grup prin Bluetooth").
///
/// Hosts a GATT Server (`CBPeripheralManager`) + BLE Advertiser alongside a Central Scanner + GATT Client
/// (`CBCentralManager`). Both managers are instantiated strictly lazily on `requestPermissions` or
/// `startDualRole` so iOS never triggers a Bluetooth system prompt on cold app launch.
public final class BleProximityPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static let methodChannelName = "com.openwanderer.wanderer/ble_proximity"
  private static let eventChannelName = "com.openwanderer.wanderer/ble_proximity/events"

  static let serviceUUID = CBUUID(string: "7a4e0001-8c3b-4f2d-9e1a-5b6c7d8e9f00")
  static let serviceDataUUID = CBUUID(string: "7A4E")
  static let syncReadUUID = CBUUID(string: "7a4e0002-8c3b-4f2d-9e1a-5b6c7d8e9f00")
  static let meshIngressUUID = CBUUID(string: "7a4e0003-8c3b-4f2d-9e1a-5b6c7d8e9f00")

  private static let maxConcurrentConnections = 6
  private static let maxQueuedNotifications = 8
  private static let connectTimeoutSec: TimeInterval = 10.0
  private static let peerContextExpirySec: TimeInterval = 300.0

  private struct PeerConnectionContext {
    let peripheral: CBPeripheral
    var lastRssi: Int
    var lastSeenAt: TimeInterval
    var lastSyncAttemptAt: TimeInterval
    var lastSyncReadAt: TimeInterval
    var connectStartedAt: TimeInterval?
    var lastAdvertisedDigest: Data?
    var lastPushedLocalDigest: Data?
    var syncReadChar: CBCharacteristic?
    var meshIngressChar: CBCharacteristic?
  }

  private let bleQueue = DispatchQueue(
    label: "com.openwanderer.wanderer.ble_proximity",
    qos: .userInitiated
  )

  // EventSink is owned and mutated only on DispatchQueue.main.
  private var eventSink: FlutterEventSink?

  // All BLE state below is owned and mutated exclusively on `bleQueue`.
  private var centralManager: CBCentralManager?
  private var peripheralManager: CBPeripheralManager?

  private var gattService: CBMutableService?
  private var syncReadCharacteristic: CBMutableCharacteristic?
  private var meshIngressCharacteristic: CBMutableCharacteristic?
  private var serviceAdded = false
  private var serviceAddInFlight = false

  private var isRunning = false
  private var isScanning = false
  private var currentMode: String = "passive_guard"
  private var syncDigest = Data(count: 8)
  private var syncBuffer = Data([0x00])
  private var latestPushFrame: Data?

  private var peerStates: [UUID: PeerConnectionContext] = [:]
  private var pendingSubscriberNotifications: [Data] = []
  private var pendingPermissionResults: [FlutterResult] = []
  private var permissionTimeoutWorkItem: DispatchWorkItem?
  private var maintenanceTimer: DispatchSourceTimer?
  private var lastScanRestartAt: TimeInterval = 0
  private var lastEmittedAdapterOn: Bool?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = BleProximityPlugin()
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
  }

  // MARK: - FlutterStreamHandler

  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    self.eventSink = events
    bleQueue.async { [weak self] in
      guard let self = self else { return }
      // Never instantiate managers in onListen; only report state if already initialized.
      if self.centralManager != nil || self.peripheralManager != nil {
        let isOn = self.computeAdapterOn()
        self.lastEmittedAdapterOn = isOn
        self.emitEvent(["type": "adapterState", "adapterOn": isOn])
      }
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  // MARK: - FlutterPlugin MethodCallHandler

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getState":
      bleQueue.async { [weak self] in
        guard let self = self else { return }
        let auth = CBManager.authorization
        let permissionsGranted = (auth == .allowedAlways)
        let centralState = self.centralManager?.state
        let peripheralState = self.peripheralManager?.state
        let supported = (centralState != .unsupported)
          && (peripheralState != .unsupported)
          && (auth != .restricted)
        let adapterOn = self.computeAdapterOn()
        let running = self.isRunning
        DispatchQueue.main.async {
          result([
            "supported": supported,
            "adapterOn": adapterOn,
            "permissionsGranted": permissionsGranted,
            "running": running,
          ])
        }
      }

    case "checkPermissions":
      let granted = (CBManager.authorization == .allowedAlways)
      DispatchQueue.main.async {
        result(granted)
      }

    case "requestPermissions":
      bleQueue.async { [weak self] in
        guard let self = self else { return }
        self.ensureCentralManagerOnQueue(showPowerAlert: true)
        let auth = CBManager.authorization
        if auth != .notDetermined {
          let granted = (auth == .allowedAlways)
          DispatchQueue.main.async {
            result(granted)
          }
          return
        }
        if let state = self.centralManager?.state,
           state == .unsupported || state == .unauthorized {
          DispatchQueue.main.async {
            result(false)
          }
          return
        }
        self.pendingPermissionResults.append(result)
        self.schedulePermissionResolutionFallbackOnQueue()
      }

    case "startDualRole":
      let args = call.arguments as? [String: Any]
      let mode = Self.normalizeMode(args?["mode"] as? String)
      let digest = Self.extractData(args?["syncDigest"] ?? args?["syncDigest8B"]) ?? Data(count: 8)
      let buffer = Self.extractData(args?["syncBuffer"] ?? args?["syncBufferBytes"]) ?? Data([0x00])
      let pushFrame = Self.extractData(args?["pushFrame"] ?? args?["pushFrameBytes"])

      bleQueue.async { [weak self] in
        guard let self = self else { return }
        if mode == "idle_off" {
          self.stopDualRoleOnQueue()
          DispatchQueue.main.async {
            result(true)
          }
          return
        }

        self.currentMode = mode
        self.syncDigest = digest
        self.syncBuffer = buffer
        if let pushFrame = pushFrame, !pushFrame.isEmpty {
          self.latestPushFrame = pushFrame
        }
        self.isRunning = true

        self.ensureCentralManagerOnQueue(showPowerAlert: mode == "sos_emergency")
        self.ensurePeripheralManagerOnQueue()
        self.startMaintenanceTimerOnQueue()

        if self.peripheralManager?.state == .poweredOn {
          self.setupGattAndAdvertisingOnQueue()
        }
        if self.centralManager?.state == .poweredOn {
          self.restartScanningOnQueue()
        }
        if let pushFrame = pushFrame, !pushFrame.isEmpty {
          self.broadcastPushFrameOnQueue(pushFrame)
        }

        let auth = CBManager.authorization
        let ok = (auth != .denied && auth != .restricted)
        DispatchQueue.main.async {
          result(ok)
        }
      }

    case "updateLocalPayloads":
      let args = call.arguments as? [String: Any]
      let rawMode = args?["mode"] as? String
      let digest = Self.extractData(args?["syncDigest"] ?? args?["syncDigest8B"])
      let buffer = Self.extractData(args?["syncBuffer"] ?? args?["syncBufferBytes"])
      let pushFrame = Self.extractData(args?["pushFrame"] ?? args?["pushFrameBytes"])

      bleQueue.async { [weak self] in
        guard let self = self else { return }
        var modeChanged = false
        if let rawMode = rawMode {
          let normalized = Self.normalizeMode(rawMode)
          if normalized == "idle_off" {
            self.stopDualRoleOnQueue()
            DispatchQueue.main.async {
              result(true)
            }
            return
          }
          if normalized != self.currentMode {
            self.currentMode = normalized
            modeChanged = true
          }
        }
        if let digest = digest {
          self.syncDigest = digest
        }
        if let buffer = buffer {
          self.syncBuffer = buffer
        }

        if self.isRunning {
          if self.peripheralManager?.state == .poweredOn {
            self.setupGattAndAdvertisingOnQueue()
          }
          if modeChanged, self.centralManager?.state == .poweredOn {
            self.restartScanningOnQueue()
          }
          if let pushFrame = pushFrame, !pushFrame.isEmpty {
            self.latestPushFrame = pushFrame
            self.broadcastPushFrameOnQueue(pushFrame)
          }
        }

        DispatchQueue.main.async {
          result(true)
        }
      }

    case "stopDualRole":
      bleQueue.async { [weak self] in
        guard let self = self else { return }
        self.stopDualRoleOnQueue()
        DispatchQueue.main.async {
          result(true)
        }
      }

    default:
      DispatchQueue.main.async {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Internal Queue Helpers (`bleQueue`)

  private func ensureCentralManagerOnQueue(showPowerAlert: Bool) {
    guard centralManager == nil else { return }
    centralManager = CBCentralManager(
      delegate: self,
      queue: bleQueue,
      options: [CBCentralManagerOptionShowPowerAlertKey: showPowerAlert]
    )
  }

  private func ensurePeripheralManagerOnQueue() {
    guard peripheralManager == nil else { return }
    peripheralManager = CBPeripheralManager(
      delegate: self,
      queue: bleQueue,
      options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
    )
  }

  private func computeAdapterOn() -> Bool {
    if let cm = centralManager, cm.state == .poweredOn {
      return true
    }
    if let pm = peripheralManager, pm.state == .poweredOn {
      return true
    }
    return false
  }

  private func emitAdapterStateIfChangedOnQueue() {
    let isOn = computeAdapterOn()
    if lastEmittedAdapterOn != isOn {
      lastEmittedAdapterOn = isOn
      emitEvent(["type": "adapterState", "adapterOn": isOn])
    }
  }

  private func emitEvent(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }

  private func schedulePermissionResolutionFallbackOnQueue() {
    guard permissionTimeoutWorkItem == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.permissionTimeoutWorkItem = nil
      self.resolvePendingPermissionResultsOnQueue()
    }
    permissionTimeoutWorkItem = work
    bleQueue.asyncAfter(deadline: .now() + 10.0, execute: work)
  }

  private func resolvePendingPermissionResultsOnQueue() {
    guard !pendingPermissionResults.isEmpty else { return }
    permissionTimeoutWorkItem?.cancel()
    permissionTimeoutWorkItem = nil
    let callbacks = pendingPermissionResults
    pendingPermissionResults.removeAll()
    let granted = (CBManager.authorization == .allowedAlways)
    DispatchQueue.main.async {
      for cb in callbacks {
        cb(granted)
      }
    }
  }

  private var isSyncBufferEmptyOnQueue: Bool {
    if syncBuffer.isEmpty {
      return true
    }
    if syncBuffer.count == 1 && syncBuffer[syncBuffer.startIndex] == 0 {
      return true
    }
    return false
  }

  private var shouldAdvertiseOnQueue: Bool {
    guard isRunning else { return false }
    if currentMode == "passive_guard" && isSyncBufferEmptyOnQueue {
      return false
    }
    return true
  }

  private var peerCooldownSecondsOnQueue: TimeInterval {
    switch currentMode {
    case "sos_emergency":
      return 4.5
    case "group_normal":
      return 5.0
    default:
      return 12.0
    }
  }

  private var shouldKeepConnectionAliveOnQueue: Bool {
    return currentMode == "sos_emergency" || currentMode == "group_normal"
  }

  private func setupGattAndAdvertisingOnQueue() {
    guard let pm = peripheralManager, pm.state == .poweredOn else { return }

    if !serviceAdded && !serviceAddInFlight {
      let readChar = CBMutableCharacteristic(
        type: Self.syncReadUUID,
        properties: [.read],
        value: nil,
        permissions: [.readable]
      )
      let ingressChar = CBMutableCharacteristic(
        type: Self.meshIngressUUID,
        properties: [.writeWithoutResponse, .write, .notify],
        value: nil,
        permissions: [.writeable]
      )
      let service = CBMutableService(type: Self.serviceUUID, primary: true)
      service.characteristics = [readChar, ingressChar]

      self.syncReadCharacteristic = readChar
      self.meshIngressCharacteristic = ingressChar
      self.gattService = service
      self.serviceAddInFlight = true
      pm.add(service)
      return
    }

    if serviceAdded {
      updateAdvertisingOnQueue()
    }
  }

  private func updateAdvertisingOnQueue() {
    guard let pm = peripheralManager, pm.state == .poweredOn, serviceAdded else { return }
    if shouldAdvertiseOnQueue {
      if !pm.isAdvertising {
        pm.startAdvertising([
          CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]
        ])
      }
    } else if pm.isAdvertising {
      pm.stopAdvertising()
    }
  }

  private func restartScanningOnQueue() {
    guard let cm = centralManager, cm.state == .poweredOn, isRunning else { return }
    if isScanning {
      cm.stopScan()
    }
    let allowDuplicates = (currentMode == "sos_emergency")
    cm.scanForPeripherals(
      withServices: [Self.serviceUUID],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
    )
    isScanning = true
    lastScanRestartAt = Date().timeIntervalSince1970
  }

  private func broadcastPushFrameOnQueue(_ frame: Data) {
    guard !frame.isEmpty else { return }

    // 1. Notify subscribed Centrals via our local GATT Server (`CHAR_MESH_INGRESS`).
    if let pm = peripheralManager,
       pm.state == .poweredOn,
       serviceAdded,
       let ingressChar = meshIngressCharacteristic {
      let sent = pm.updateValue(frame, for: ingressChar, onSubscribedCentrals: nil)
      if !sent {
        if pendingSubscriberNotifications.count >= Self.maxQueuedNotifications {
          pendingSubscriberNotifications.removeFirst()
        }
        pendingSubscriberNotifications.append(frame)
      }
    }

    // 2. Write directly to connected Peripherals' `CHAR_MESH_INGRESS`.
    for (peerId, var context) in peerStates {
      guard context.peripheral.state == .connected,
            let remoteIngress = context.meshIngressChar else {
        continue
      }
      writeFrameToPeripheralOnQueue(
        context.peripheral,
        characteristic: remoteIngress,
        frame: frame
      )
      context.lastPushedLocalDigest = syncDigest
      peerStates[peerId] = context
    }
  }

  private func flushQueuedSubscriberNotificationsOnQueue() {
    guard let pm = peripheralManager,
          pm.state == .poweredOn,
          serviceAdded,
          let ingressChar = meshIngressCharacteristic else {
      return
    }
    while let nextFrame = pendingSubscriberNotifications.first {
      if pm.updateValue(nextFrame, for: ingressChar, onSubscribedCentrals: nil) {
        pendingSubscriberNotifications.removeFirst()
      } else {
        break
      }
    }
  }

  private func pushLocalFramesIfNeededOnQueue(for peerId: UUID) {
    guard var context = peerStates[peerId],
          context.peripheral.state == .connected,
          let remoteIngress = context.meshIngressChar else {
      return
    }
    guard context.lastPushedLocalDigest != syncDigest else { return }

    let unpacked = Self.unpackFramesFromSyncBuffer(syncBuffer)
    if !unpacked.isEmpty {
      for frame in unpacked {
        writeFrameToPeripheralOnQueue(
          context.peripheral,
          characteristic: remoteIngress,
          frame: frame
        )
      }
      context.lastPushedLocalDigest = syncDigest
      peerStates[peerId] = context
    } else if let latest = latestPushFrame, !latest.isEmpty {
      writeFrameToPeripheralOnQueue(
        context.peripheral,
        characteristic: remoteIngress,
        frame: latest
      )
      context.lastPushedLocalDigest = syncDigest
      peerStates[peerId] = context
    }
  }

  private func writeFrameToPeripheralOnQueue(
    _ peripheral: CBPeripheral,
    characteristic: CBCharacteristic,
    frame: Data
  ) {
    guard !frame.isEmpty else { return }
    if characteristic.properties.contains(.writeWithoutResponse) {
      let maxLen = peripheral.maximumWriteValueLength(for: .withoutResponse)
      if maxLen == 0 || frame.count <= maxLen {
        peripheral.writeValue(frame, for: characteristic, type: .withoutResponse)
        return
      }
    }
    if characteristic.properties.contains(.write) {
      peripheral.writeValue(frame, for: characteristic, type: .withResponse)
    }
  }

  private func startMaintenanceTimerOnQueue() {
    guard maintenanceTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: bleQueue)
    timer.schedule(deadline: .now() + 5.0, repeating: 5.0, leeway: .milliseconds(500))
    timer.setEventHandler { [weak self] in
      self?.runMaintenanceTickOnQueue()
    }
    maintenanceTimer = timer
    timer.resume()
  }

  private func stopMaintenanceTimerOnQueue() {
    maintenanceTimer?.cancel()
    maintenanceTimer = nil
  }

  private func runMaintenanceTickOnQueue() {
    guard isRunning else { return }
    let now = Date().timeIntervalSince1970

    for (peerId, var context) in peerStates {
      let state = context.peripheral.state
      if state == .connecting,
         let started = context.connectStartedAt,
         now - started > Self.connectTimeoutSec {
        centralManager?.cancelPeripheralConnection(context.peripheral)
        context.connectStartedAt = nil
        peerStates[peerId] = context
        continue
      }

      if state == .connected {
        // Periodic fallback sync read in SOS / group mode in case an RF fade dropped a notification.
        if shouldKeepConnectionAliveOnQueue,
           now - context.lastSyncReadAt >= 15.0,
           let readChar = context.syncReadChar {
          context.lastSyncAttemptAt = now
          peerStates[peerId] = context
          context.peripheral.readRSSI()
          context.peripheral.readValue(for: readChar)
        }
        continue
      }

      if state == .disconnected, now - context.lastSeenAt > Self.peerContextExpirySec {
        context.peripheral.delegate = nil
        peerStates.removeValue(forKey: peerId)
      }
    }

    // When duplicates are coalesced (`allowDuplicates == false`), refresh scan periodically
    // so non-connected peers whose payloads changed are promptly re-evaluated.
    if let cm = centralManager, cm.state == .poweredOn {
      let refreshInterval: TimeInterval = (currentMode == "group_normal") ? 12.0 : 25.0
      if !isScanning || (currentMode != "sos_emergency" && now - lastScanRestartAt >= refreshInterval) {
        restartScanningOnQueue()
      }
    }
  }

  private func stopDualRoleOnQueue() {
    isRunning = false
    stopMaintenanceTimerOnQueue()
    pendingSubscriberNotifications.removeAll()
    latestPushFrame = nil

    if let cm = centralManager {
      if isScanning {
        cm.stopScan()
      }
      for context in peerStates.values {
        context.peripheral.delegate = nil
        if context.peripheral.state == .connected || context.peripheral.state == .connecting {
          cm.cancelPeripheralConnection(context.peripheral)
        }
      }
    }
    isScanning = false
    peerStates.removeAll()

    if let pm = peripheralManager {
      if pm.isAdvertising {
        pm.stopAdvertising()
      }
    }
  }

  // MARK: - Pure Static Utilities

  private static func normalizeMode(_ raw: String?) -> String {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !trimmed.isEmpty else {
      return "passive_guard"
    }
    if trimmed.contains("sos") {
      return "sos_emergency"
    }
    if trimmed.contains("group") {
      return "group_normal"
    }
    if trimmed.contains("idle") || trimmed == "off" {
      return "idle_off"
    }
    return "passive_guard"
  }

  private static func extractData(_ raw: Any?) -> Data? {
    if let typed = raw as? FlutterStandardTypedData {
      return typed.data
    }
    if let data = raw as? Data {
      return data
    }
    if let bytes = raw as? [UInt8] {
      return Data(bytes)
    }
    return nil
  }

  private static func normalizeRssi(_ rssi: NSNumber?) -> Int {
    guard let value = rssi?.intValue else { return -70 }
    if value == 127 || value > 0 || value < -127 {
      return -70
    }
    return value
  }

  /// Unpacks valid `[0x54, pktType, ttlHops, bodyLen, ...]` frames from a packed GATT `syncBuffer`.
  private static func unpackFramesFromSyncBuffer(_ buf: Data) -> [Data] {
    guard !buf.isEmpty else { return [] }
    let bytes = [UInt8](buf)

    // Single raw frame fallback (`magicVer == 0x54`).
    if bytes[0] == 0x54, bytes.count >= 30 {
      let bodyLen = Int(bytes[3])
      if bodyLen >= 26, bodyLen <= 84, 4 + bodyLen == bytes.count {
        return [buf]
      }
    }

    let count = Int(bytes[0])
    guard count > 0, count <= 16 else { return [] }

    var frames: [Data] = []
    var offset = 1
    while frames.count < count && offset + 4 <= bytes.count {
      guard bytes[offset] == 0x54 else { break }
      let bodyLen = Int(bytes[offset + 3])
      let frameLen = 4 + bodyLen
      guard bodyLen >= 26, bodyLen <= 84, offset + frameLen <= bytes.count else { break }
      frames.append(Data(bytes[offset..<(offset + frameLen)]))
      offset += frameLen
    }
    return frames
  }
}

// MARK: - CBCentralManagerDelegate

extension BleProximityPlugin: CBCentralManagerDelegate {
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    emitAdapterStateIfChangedOnQueue()

    if CBManager.authorization != .notDetermined
        || central.state == .unsupported
        || central.state == .unauthorized {
      resolvePendingPermissionResultsOnQueue()
    }

    if central.state == .poweredOn {
      if isRunning {
        restartScanningOnQueue()
      }
    } else {
      isScanning = false
      for (peerId, var context) in peerStates {
        context.connectStartedAt = nil
        context.syncReadChar = nil
        context.meshIngressChar = nil
        peerStates[peerId] = context
      }
    }
  }

  public func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    guard isRunning else { return }
    let rawRssi = RSSI.intValue
    if rawRssi < 0 && rawRssi < -98 {
      return
    }
    let normalizedRssi = Self.normalizeRssi(RSSI)
    let now = Date().timeIntervalSince1970
    let peerId = peripheral.identifier

    let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
    let advDigest = serviceData?[Self.serviceDataUUID] ?? serviceData?[Self.serviceUUID]

    var existing = peerStates[peerId] ?? PeerConnectionContext(
      peripheral: peripheral,
      lastRssi: normalizedRssi,
      lastSeenAt: now,
      lastSyncAttemptAt: 0,
      lastSyncReadAt: 0,
      connectStartedAt: nil,
      lastAdvertisedDigest: nil,
      lastPushedLocalDigest: nil,
      syncReadChar: nil,
      meshIngressChar: nil
    )
    existing.lastRssi = normalizedRssi
    existing.lastSeenAt = now

    let digestChanged = (advDigest != nil && advDigest != existing.lastAdvertisedDigest)
    if let advDigest = advDigest {
      existing.lastAdvertisedDigest = advDigest
      // Connectionless Android 0x7A4E fast-path: if peer has 0 flags (`advDigest[0] == 0`)
      // and we are in passive_guard with nothing to push, skip GATT connect altogether.
      if currentMode == "passive_guard",
         let flags = advDigest.first,
         flags == 0,
         isSyncBufferEmptyOnQueue,
         latestPushFrame == nil {
        peerStates[peerId] = existing
        return
      }
    }

    let cooldown = peerCooldownSecondsOnQueue

    if peripheral.state == .connected {
      if digestChanged || (now - existing.lastSyncReadAt >= cooldown) {
        if let readChar = existing.syncReadChar {
          existing.lastSyncAttemptAt = now
          peerStates[peerId] = existing
          peripheral.readValue(for: readChar)
          pushLocalFramesIfNeededOnQueue(for: peerId)
          return
        }
      }
      peerStates[peerId] = existing
      return
    }

    if peripheral.state == .connecting {
      if let started = existing.connectStartedAt, now - started > Self.connectTimeoutSec {
        central.cancelPeripheralConnection(peripheral)
        existing.connectStartedAt = nil
      }
      peerStates[peerId] = existing
      return
    }

    if !digestChanged && (now - existing.lastSyncAttemptAt < cooldown) {
      peerStates[peerId] = existing
      return
    }

    let activeCount = peerStates.values.reduce(0) { acc, ctx in
      let st = ctx.peripheral.state
      return (st == .connected || st == .connecting) ? (acc + 1) : acc
    }
    if activeCount >= Self.maxConcurrentConnections {
      peerStates[peerId] = existing
      return
    }

    peripheral.delegate = self
    existing.connectStartedAt = now
    existing.lastSyncAttemptAt = now
    peerStates[peerId] = existing
    central.connect(peripheral, options: nil)
  }

  public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard isRunning else {
      central.cancelPeripheralConnection(peripheral)
      return
    }
    let peerId = peripheral.identifier
    if var context = peerStates[peerId] {
      context.connectStartedAt = nil
      context.lastSeenAt = Date().timeIntervalSince1970
      peerStates[peerId] = context
    }
    peripheral.delegate = self
    peripheral.discoverServices([Self.serviceUUID])
  }

  public func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    let peerId = peripheral.identifier
    if var context = peerStates[peerId] {
      context.connectStartedAt = nil
      peerStates[peerId] = context
    }
  }

  public func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    let peerId = peripheral.identifier
    if var context = peerStates[peerId] {
      context.connectStartedAt = nil
      context.syncReadChar = nil
      context.meshIngressChar = nil
      peerStates[peerId] = context
    }
  }
}

// MARK: - CBPeripheralDelegate

extension BleProximityPlugin: CBPeripheralDelegate {
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard error == nil, isRunning else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }
    guard let services = peripheral.services,
          let meshService = services.first(where: { $0.uuid == Self.serviceUUID }) else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.discoverCharacteristics(
      [Self.syncReadUUID, Self.meshIngressUUID],
      for: meshService
    )
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard error == nil, isRunning, service.uuid == Self.serviceUUID else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }
    let peerId = peripheral.identifier
    guard var context = peerStates[peerId] else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }

    let chars = service.characteristics ?? []
    let readChar = chars.first(where: { $0.uuid == Self.syncReadUUID })
    let ingressChar = chars.first(where: { $0.uuid == Self.meshIngressUUID })

    context.syncReadChar = readChar
    context.meshIngressChar = ingressChar
    peerStates[peerId] = context

    if let ingressChar = ingressChar,
       ingressChar.properties.contains(.notify),
       !ingressChar.isNotifying,
       shouldKeepConnectionAliveOnQueue {
      // Herald Mutual GATT Notification Keep-Alive: keeps a low-power link open
      // between locked iPhones in pockets so SOS/Group frames arrive in < 30 ms.
      peripheral.setNotifyValue(true, for: ingressChar)
    }

    if let readChar = readChar {
      peripheral.readValue(for: readChar)
    }

    pushLocalFramesIfNeededOnQueue(for: peerId)
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    let peerId = peripheral.identifier
    let now = Date().timeIntervalSince1970

    if error != nil {
      if !shouldKeepConnectionAliveOnQueue {
        centralManager?.cancelPeripheralConnection(peripheral)
      }
      return
    }

    var rssi = -70
    if var context = peerStates[peerId] {
      context.lastSeenAt = now
      rssi = context.lastRssi
      if characteristic.uuid == Self.syncReadUUID {
        context.lastSyncReadAt = now
      }
      peerStates[peerId] = context
    }

    guard let data = characteristic.value, !data.isEmpty else {
      if characteristic.uuid == Self.syncReadUUID && !shouldKeepConnectionAliveOnQueue {
        centralManager?.cancelPeripheralConnection(peripheral)
      }
      return
    }

    if characteristic.uuid == Self.syncReadUUID {
      let peerHasActivePayload = !(data.count == 1 && data[data.startIndex] == 0)
      if peerHasActivePayload {
        emitEvent([
          "type": "syncBuffer",
          "bytes": FlutterStandardTypedData(bytes: data),
          "rssi": rssi,
          "peerId": peerId.uuidString,
        ])
        // If passive_guard discovered a peer actively carrying an SOS payload, subscribe
        // to notifications so follow-up coordinates/resolutions stream cleanly.
        if !shouldKeepConnectionAliveOnQueue,
           let ingressChar = peerStates[peerId]?.meshIngressChar,
           ingressChar.properties.contains(.notify),
           !ingressChar.isNotifying {
          peripheral.setNotifyValue(true, for: ingressChar)
          return
        }
      }

      if !shouldKeepConnectionAliveOnQueue {
        centralManager?.cancelPeripheralConnection(peripheral)
      }
    } else if characteristic.uuid == Self.meshIngressUUID {
      emitEvent([
        "type": "frame",
        "bytes": FlutterStandardTypedData(bytes: data),
        "rssi": rssi,
        "peerId": peerId.uuidString,
      ])
    }
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    // No-op: satisfies CBPeripheralDelegate when `.withResponse` fallback is used.
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    // Keep-alive notification subscription state updated.
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didReadRSSI RSSI: NSNumber,
    error: Error?
  ) {
    guard error == nil else { return }
    let peerId = peripheral.identifier
    if var context = peerStates[peerId] {
      context.lastRssi = Self.normalizeRssi(RSSI)
      peerStates[peerId] = context
    }
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didModifyServices invalidatedServices: [CBService]
  ) {
    guard isRunning else { return }
    if invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }) {
      peripheral.discoverServices([Self.serviceUUID])
    }
  }
}

// MARK: - CBPeripheralManagerDelegate

extension BleProximityPlugin: CBPeripheralManagerDelegate {
  public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    emitAdapterStateIfChangedOnQueue()

    if peripheral.state == .poweredOn {
      if isRunning {
        setupGattAndAdvertisingOnQueue()
      }
    } else {
      serviceAdded = false
      serviceAddInFlight = false
      gattService = nil
      syncReadCharacteristic = nil
      meshIngressCharacteristic = nil
      pendingSubscriberNotifications.removeAll()
    }
  }

  public func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didAdd service: CBService,
    error: Error?
  ) {
    serviceAddInFlight = false
    guard error == nil else {
      serviceAdded = false
      return
    }
    serviceAdded = true
    updateAdvertisingOnQueue()
  }

  public func peripheralManagerDidStartAdvertising(
    _ peripheral: CBPeripheralManager,
    error: Error?
  ) {
    // Advertising state tracked directly via `peripheral.isAdvertising`.
  }

  public func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didReceiveRead request: CBATTRequest
  ) {
    guard request.characteristic.uuid == Self.syncReadUUID else {
      peripheral.respond(to: request, withResult: .attributeNotFound)
      return
    }
    let payload = syncBuffer
    if request.offset > payload.count {
      peripheral.respond(to: request, withResult: .invalidOffset)
      return
    }
    if request.offset == payload.count {
      request.value = Data()
    } else {
      request.value = payload.subdata(in: request.offset..<payload.count)
    }
    peripheral.respond(to: request, withResult: .success)
  }

  public func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didReceiveWrite requests: [CBATTRequest]
  ) {
    guard let firstRequest = requests.first else { return }

    for req in requests {
      guard req.characteristic.uuid == Self.meshIngressUUID else {
        peripheral.respond(to: firstRequest, withResult: .requestNotSupported)
        return
      }
      if let data = req.value, !data.isEmpty {
        emitEvent([
          "type": "frame",
          "bytes": FlutterStandardTypedData(bytes: data),
          "rssi": -65,
          "peerId": req.central.identifier.uuidString,
        ])
      }
    }

    // CoreBluetooth rule: call `respond(to:withResult:)` once with `requests[0]`.
    peripheral.respond(to: firstRequest, withResult: .success)
  }

  public func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    flushQueuedSubscriberNotificationsOnQueue()
  }

  public func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    // Subscription cleaned up automatically by CoreBluetooth.
  }

  public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    flushQueuedSubscriberNotificationsOnQueue()
  }
}
