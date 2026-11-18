package com.openwanderer.wanderer

import android.Manifest
import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.util.Arrays
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Zero-dependency dual-role BLE plugin (GATT Server + BLE Advertiser + BLE Scanner + GATT Client)
 * for offline multi-hop SOS alerts and trail group position sharing.
 *
 * Designed for bidirectional Android <-> Android and Android <-> screen-locked iOS discovery
 * without OS Bluetooth pairing dialogs (end-to-end packet authentication happens in Dart).
 */
@SuppressLint("MissingPermission")
class BleProximityPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private var appContext: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingPermissionResults = mutableListOf<MethodChannel.Result>()

    private var bluetoothReceiverRegistered = false

    @Volatile
    private var isRunning = false

    @Volatile
    private var currentMode: String = MODE_PASSIVE_GUARD

    @Volatile
    private var localSyncDigest: ByteArray = ByteArray(DIGEST_LENGTH_BYTES)

    @Volatile
    private var localSyncBuffer: ByteArray = ByteArray(0)

    // GATT Server state (Peripheral role)
    private var gattServer: BluetoothGattServer? = null
    private var gattIngressCharacteristic: BluetoothGattCharacteristic? = null
    private val subscribedCentrals = ConcurrentHashMap<String, BluetoothDevice>()
    private val preparedWriteBuffers = ConcurrentHashMap<String, ByteArrayOutputStream>()

    // BLE Advertiser state
    private var activeAdvertiser: BluetoothLeAdvertiser? = null
    private var isAdvertising = false
    private var lastAdvertisedMode: String? = null
    private var lastAdvertisedDigest: ByteArray? = null

    // BLE Scanner state (Central role)
    private var activeScanner: BluetoothLeScanner? = null
    private var isScanning = false
    private var activeScanMode: Int = ScanSettings.SCAN_MODE_LOW_POWER
    private var lastScanStartElapsedMs: Long = 0L
    private var pendingScanRestartRunnable: Runnable? = null

    // Peer discovery caches & GATT client sessions
    private val peerLastRssi = ConcurrentHashMap<String, Int>()
    private val peerLastSyncedDigest = ConcurrentHashMap<String, ByteArray>()
    private val peerLastPushedDigest = ConcurrentHashMap<String, ByteArray>()
    private val peerLastConnectAttemptMs = ConcurrentHashMap<String, Long>()
    private val negativeAppleCache = ConcurrentHashMap<String, Long>()
    private val knownWandererApplePeers = ConcurrentHashMap<String, Long>()
    private val peerSessions = ConcurrentHashMap<String, PeerGattSession>()

    // -------------------------------------------------------------------------
    // FlutterPlugin & ActivityAware lifecycle
    // -------------------------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        appContext = context

        val mChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL_NAME)
        mChannel.setMethodCallHandler(this)
        methodChannel = mChannel

        val eChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL_NAME)
        eChannel.setStreamHandler(this)
        eventChannel = eChannel

        registerBluetoothStateReceiver(context)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopDualRoleInternal()
        unregisterBluetoothStateReceiver(binding.applicationContext)

        methodChannel?.setMethodCallHandler(null)
        methodChannel = null

        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
        appContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null

        if (pendingPermissionResults.isNotEmpty()) {
            val granted = hasBlePermissions()
            val pending = pendingPermissionResults.toList()
            pendingPermissionResults.clear()
            mainHandler.post {
                for (res in pending) {
                    res.success(granted)
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // EventChannel.StreamHandler
    // -------------------------------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emitEvent(payload: Map<String, Any>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventSink?.success(payload)
        } else {
            mainHandler.post {
                eventSink?.success(payload)
            }
        }
    }

    // -------------------------------------------------------------------------
    // MethodChannel.MethodCallHandler
    // -------------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getState" -> {
                val stateMap = mapOf(
                    "supported" to isBleSupported(),
                    "adapterOn" to isAdapterOn(),
                    "permissionsGranted" to hasBlePermissions(),
                    "running" to isRunning,
                )
                replySuccessOnMain(result, stateMap)
            }

            "checkPermissions" -> {
                replySuccessOnMain(result, hasBlePermissions())
            }

            "requestPermissions" -> {
                handleRequestPermissions(result)
            }

            "startDualRole" -> {
                val mode = normalizeMode(call.argument<String>("mode"))
                if (mode == MODE_IDLE_OFF) {
                    stopDualRoleInternal()
                    replySuccessOnMain(result, true)
                    return
                }
                val rawDigest = call.argument<Any>("syncDigest") ?: call.argument<Any>("syncDigest8B")
                val rawBuffer = call.argument<Any>("syncBuffer") ?: call.argument<Any>("syncBufferBytes")
                val rawPush = call.argument<Any>("pushFrame") ?: call.argument<Any>("pushFrameBytes")

                val digest = normalizeDigest8B(extractBytes(rawDigest))
                val buffer = clampSyncBuffer(extractBytes(rawBuffer))
                val pushFrame = extractBytes(rawPush)

                if (!isBleSupported() || !hasBlePermissions()) {
                    replySuccessOnMain(result, false)
                    return
                }

                currentMode = mode
                localSyncDigest = digest
                localSyncBuffer = buffer
                isRunning = true

                if (isAdapterOn()) {
                    startBleStackInternal()
                    if (pushFrame != null && pushFrame.isNotEmpty()) {
                        notifySubscribedCentrals(pushFrame)
                        pushFrameToConnectedPeripherals(pushFrame, digest)
                    }
                }
                replySuccessOnMain(result, true)
            }

            "updateLocalPayloads" -> {
                val modeArg = call.argument<String>("mode")
                val nextMode = if (modeArg != null) normalizeMode(modeArg) else currentMode
                if (nextMode == MODE_IDLE_OFF) {
                    stopDualRoleInternal()
                    replySuccessOnMain(result, true)
                    return
                }
                val rawDigest = call.argument<Any>("syncDigest") ?: call.argument<Any>("syncDigest8B")
                val rawBuffer = call.argument<Any>("syncBuffer") ?: call.argument<Any>("syncBufferBytes")
                val rawPush = call.argument<Any>("pushFrame") ?: call.argument<Any>("pushFrameBytes")

                val digestArg = extractBytes(rawDigest)
                val nextDigest = if (digestArg != null) normalizeDigest8B(digestArg) else localSyncDigest
                val bufferArg = extractBytes(rawBuffer)
                val nextBuffer = if (bufferArg != null) clampSyncBuffer(bufferArg) else localSyncBuffer
                val pushFrame = extractBytes(rawPush)

                val modeChanged = nextMode != currentMode
                val digestChanged = !Arrays.equals(nextDigest, localSyncDigest)
                val prevShouldAdv = shouldAdvertise(currentMode, localSyncBuffer)
                val nextShouldAdv = shouldAdvertise(nextMode, nextBuffer)

                currentMode = nextMode
                localSyncDigest = nextDigest
                localSyncBuffer = nextBuffer

                if (isRunning && hasBlePermissions() && isAdapterOn()) {
                    if (gattServer == null) {
                        ensureGattServerStarted()
                    }
                    if (modeChanged || digestChanged || prevShouldAdv != nextShouldAdv ||
                        (nextShouldAdv && !isAdvertising)
                    ) {
                        restartAdvertisingIfNeeded()
                    }
                    if (modeChanged || !isScanning) {
                        ensureScannerMatchingMode()
                    }
                    if (pushFrame != null && pushFrame.isNotEmpty()) {
                        notifySubscribedCentrals(pushFrame)
                        pushFrameToConnectedPeripherals(pushFrame, nextDigest)
                    }
                }

                replySuccessOnMain(result, true)
            }

            "stopDualRole" -> {
                stopDualRoleInternal()
                replySuccessOnMain(result, true)
            }

            else -> {
                if (Looper.myLooper() == Looper.getMainLooper()) {
                    result.notImplemented()
                } else {
                    mainHandler.post { result.notImplemented() }
                }
            }
        }
    }

    private fun replySuccessOnMain(result: MethodChannel.Result, value: Any?) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            result.success(value)
        } else {
            mainHandler.post { result.success(value) }
        }
    }

    // -------------------------------------------------------------------------
    // Permissions & Adapter State
    // -------------------------------------------------------------------------

    private fun isBleSupported(): Boolean {
        val ctx = appContext ?: return false
        val hasFeature = ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        return hasFeature && getBluetoothAdapter() != null
    }

    private fun isAdapterOn(): Boolean {
        val adapter = getBluetoothAdapter() ?: return false
        return runCatching {
            adapter.state == BluetoothAdapter.STATE_ON || adapter.isEnabled
        }.getOrDefault(false)
    }

    private fun hasBlePermissions(): Boolean {
        val ctx = appContext ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ctx.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) ==
                PackageManager.PERMISSION_GRANTED &&
                ctx.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) ==
                PackageManager.PERMISSION_GRANTED &&
                ctx.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    private fun handleRequestPermissions(result: MethodChannel.Result) {
        if (hasBlePermissions()) {
            replySuccessOnMain(result, true)
            return
        }
        val act = activity
        if (act == null) {
            replySuccessOnMain(result, false)
            return
        }

        val shouldLaunchDialog = pendingPermissionResults.isEmpty()
        pendingPermissionResults.add(result)
        if (!shouldLaunchDialog) {
            return
        }

        val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

        try {
            act.requestPermissions(permissions, REQ_BLE_PERMISSIONS)
        } catch (e: Exception) {
            Log.w(TAG, "Failed requesting BLE permissions", e)
            val pending = pendingPermissionResults.toList()
            pendingPermissionResults.clear()
            for (res in pending) {
                replySuccessOnMain(res, hasBlePermissions())
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_BLE_PERMISSIONS) {
            return false
        }
        val allGranted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED } &&
            hasBlePermissions()

        val pending = pendingPermissionResults.toList()
        pendingPermissionResults.clear()
        for (res in pending) {
            replySuccessOnMain(res, allGranted)
        }
        return true
    }

    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_ON -> {
                    emitEvent(mapOf("type" to "adapterState", "adapterOn" to true))
                    mainHandler.post {
                        if (isRunning && hasBlePermissions() && isAdapterOn()) {
                            startBleStackInternal()
                        }
                    }
                }

                BluetoothAdapter.STATE_TURNING_OFF -> {
                    mainHandler.post {
                        teardownBleHandlesPreservingRunningFlag()
                    }
                }

                BluetoothAdapter.STATE_OFF -> {
                    emitEvent(mapOf("type" to "adapterState", "adapterOn" to false))
                    mainHandler.post {
                        teardownBleHandlesPreservingRunningFlag()
                    }
                }
            }
        }
    }

    private fun registerBluetoothStateReceiver(context: Context) {
        if (bluetoothReceiverRegistered) return
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(bluetoothStateReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                context.registerReceiver(bluetoothStateReceiver, filter)
            }
            bluetoothReceiverRegistered = true
        } catch (e: Exception) {
            Log.w(TAG, "Could not register Bluetooth state receiver", e)
        }
    }

    private fun unregisterBluetoothStateReceiver(context: Context) {
        if (!bluetoothReceiverRegistered) return
        try {
            context.unregisterReceiver(bluetoothStateReceiver)
        } catch (_: IllegalArgumentException) {
            // Receiver already unregistered.
        } finally {
            bluetoothReceiverRegistered = false
        }
    }

    private fun getBluetoothManager(): BluetoothManager? {
        val ctx = appContext ?: return null
        return ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    }

    private fun getBluetoothAdapter(): BluetoothAdapter? {
        return getBluetoothManager()?.adapter
    }

    // -------------------------------------------------------------------------
    // Dual-Role Stack Orchestration
    // -------------------------------------------------------------------------

    private fun startBleStackInternal() {
        if (!hasBlePermissions() || !isAdapterOn()) return
        ensureGattServerStarted()
        restartAdvertisingIfNeeded()
        ensureScannerMatchingMode()
    }

    private fun stopDualRoleInternal() {
        isRunning = false
        teardownBleHandlesPreservingRunningFlag()
        peerLastSyncedDigest.clear()
        peerLastPushedDigest.clear()
        peerLastConnectAttemptMs.clear()
    }

    private fun teardownBleHandlesPreservingRunningFlag() {
        pendingScanRestartRunnable?.let { mainHandler.removeCallbacks(it) }
        pendingScanRestartRunnable = null

        stopScannerSafe()
        stopAdvertisingSafe()
        closeAllGattClientsSafe()
        stopGattServerSafe()
    }

    // -------------------------------------------------------------------------
    // 1) Peripheral GATT Server (CHAR_SYNC_READ + CHAR_MESH_INGRESS)
    // -------------------------------------------------------------------------

    private fun ensureGattServerStarted() {
        if (gattServer != null) return
        val ctx = appContext ?: return
        val manager = getBluetoothManager() ?: return

        try {
            val server = manager.openGattServer(ctx, gattServerCallback) ?: return

            val service = BluetoothGattService(
                SERVICE_UUID,
                BluetoothGattService.SERVICE_TYPE_PRIMARY,
            )

            // Open unencrypted READ permission so peers never trigger an OS pairing dialog.
            val syncReadChar = BluetoothGattCharacteristic(
                CHAR_SYNC_READ_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ,
            )

            // Open WRITE_NO_RESPONSE | WRITE | NOTIFY with CCCD descriptor (no encryption/MITM).
            val meshIngressChar = BluetoothGattCharacteristic(
                CHAR_MESH_INGRESS_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
            val cccdDescriptor = BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
            )
            meshIngressChar.addDescriptor(cccdDescriptor)

            service.addCharacteristic(syncReadChar)
            service.addCharacteristic(meshIngressChar)

            server.addService(service)
            gattServer = server
            gattIngressCharacteristic = meshIngressChar
        } catch (e: SecurityException) {
            Log.w(TAG, "SecurityException opening GATT server", e)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "IllegalStateException opening GATT server", e)
        } catch (e: Exception) {
            Log.w(TAG, "Failed opening GATT server", e)
        }
    }

    private fun stopGattServerSafe() {
        subscribedCentrals.clear()
        preparedWriteBuffers.clear()
        gattIngressCharacteristic = null
        val server = gattServer ?: return
        gattServer = null
        try {
            server.clearServices()
        } catch (_: SecurityException) {
        } catch (_: IllegalStateException) {
        } catch (_: Exception) {
        }
        try {
            server.close()
        } catch (_: SecurityException) {
        } catch (_: IllegalStateException) {
        } catch (_: Exception) {
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                subscribedCentrals.remove(device.address)
                preparedWriteBuffers.remove(device.address)
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            val server = gattServer ?: return
            try {
                if (characteristic.uuid == CHAR_SYNC_READ_UUID) {
                    val buf = localSyncBuffer
                    if (offset < 0 || offset > buf.size) {
                        server.sendResponse(
                            device,
                            requestId,
                            BluetoothGatt.GATT_INVALID_OFFSET,
                            offset,
                            null,
                        )
                    } else {
                        val slice = if (offset == buf.size) {
                            ByteArray(0)
                        } else {
                            buf.copyOfRange(offset, buf.size)
                        }
                        server.sendResponse(
                            device,
                            requestId,
                            BluetoothGatt.GATT_SUCCESS,
                            offset,
                            slice,
                        )
                    }
                } else {
                    server.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_READ_NOT_PERMITTED,
                        offset,
                        null,
                    )
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed responding to characteristic read", e)
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            val server = gattServer ?: return
            if (characteristic.uuid != CHAR_MESH_INGRESS_UUID) {
                if (responseNeeded) {
                    runCatching {
                        server.sendResponse(
                            device,
                            requestId,
                            BluetoothGatt.GATT_WRITE_NOT_PERMITTED,
                            offset,
                            null,
                        )
                    }
                }
                return
            }

            if (preparedWrite) {
                val stream = preparedWriteBuffers.getOrPut(device.address) {
                    ByteArrayOutputStream(MAX_SYNC_BUFFER_BYTES)
                }
                if (stream.size() + value.size <= MAX_SYNC_BUFFER_BYTES) {
                    stream.write(value, 0, value.size)
                }
                if (responseNeeded) {
                    runCatching {
                        server.sendResponse(
                            device,
                            requestId,
                            BluetoothGatt.GATT_SUCCESS,
                            offset,
                            value,
                        )
                    }
                }
                return
            }

            if (responseNeeded) {
                runCatching {
                    server.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_SUCCESS,
                        offset,
                        value,
                    )
                }
            }

            if (value.isNotEmpty()) {
                val frameCopy = value.copyOf()
                val rssi = peerLastRssi[device.address] ?: DEFAULT_GATT_WRITE_RSSI
                emitEvent(
                    mapOf(
                        "type" to "frame",
                        "bytes" to frameCopy,
                        "rssi" to rssi,
                        "peerId" to device.address,
                    ),
                )
            }
        }

        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            val server = gattServer ?: return
            val stream = preparedWriteBuffers.remove(device.address)
            runCatching {
                server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
            if (execute && stream != null && stream.size() > 0) {
                val assembled = stream.toByteArray()
                val rssi = peerLastRssi[device.address] ?: DEFAULT_GATT_WRITE_RSSI
                emitEvent(
                    mapOf(
                        "type" to "frame",
                        "bytes" to assembled,
                        "rssi" to rssi,
                        "peerId" to device.address,
                    ),
                )
            }
        }

        override fun onDescriptorReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            descriptor: BluetoothGattDescriptor,
        ) {
            val server = gattServer ?: return
            runCatching {
                if (descriptor.uuid == CCCD_UUID) {
                    val value = if (subscribedCentrals.containsKey(device.address)) {
                        BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    } else {
                        BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                    }
                    val slice = if (offset in 0..value.size) {
                        value.copyOfRange(offset, value.size)
                    } else {
                        ByteArray(0)
                    }
                    server.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_SUCCESS,
                        offset,
                        slice,
                    )
                } else {
                    server.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_READ_NOT_PERMITTED,
                        offset,
                        null,
                    )
                }
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            val server = gattServer ?: return
            if (descriptor.uuid == CCCD_UUID) {
                val enabled = value.isNotEmpty() && (value[0].toInt() and 0x03) != 0
                if (enabled) {
                    subscribedCentrals[device.address] = device
                } else {
                    subscribedCentrals.remove(device.address)
                }
                if (responseNeeded) {
                    runCatching {
                        server.sendResponse(
                            device,
                            requestId,
                            BluetoothGatt.GATT_SUCCESS,
                            offset,
                            value,
                        )
                    }
                }
            } else if (responseNeeded) {
                runCatching {
                    server.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_WRITE_NOT_PERMITTED,
                        offset,
                        null,
                    )
                }
            }
        }
    }

    private fun notifySubscribedCentrals(frameBytes: ByteArray) {
        val server = gattServer ?: return
        val characteristic = gattIngressCharacteristic ?: return
        if (subscribedCentrals.isEmpty()) return

        for (device in subscribedCentrals.values.toList()) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    server.notifyCharacteristicChanged(device, characteristic, false, frameBytes)
                } else {
                    @Suppress("DEPRECATION")
                    characteristic.value = frameBytes
                    @Suppress("DEPRECATION")
                    server.notifyCharacteristicChanged(device, characteristic, false)
                }
            } catch (e: SecurityException) {
                Log.w(TAG, "SecurityException notifying central ${device.address}", e)
            } catch (e: IllegalStateException) {
                Log.w(TAG, "IllegalStateException notifying central ${device.address}", e)
            } catch (e: Exception) {
                Log.w(TAG, "Failed notifying central ${device.address}", e)
            }
        }
    }

    // -------------------------------------------------------------------------
    // 2) Peripheral BLE Advertiser (Primary ServiceUUID + ScanRsp 0x7A4E Digest)
    // -------------------------------------------------------------------------

    private fun shouldAdvertise(mode: String, buffer: ByteArray): Boolean {
        if (mode == MODE_PASSIVE_GUARD && buffer.size <= 1) {
            return false
        }
        return true
    }

    private fun restartAdvertisingIfNeeded() {
        val mode = currentMode
        val digest = localSyncDigest.copyOf()
        val buffer = localSyncBuffer

        if (!shouldAdvertise(mode, buffer)) {
            stopAdvertisingSafe()
            return
        }

        if (isAdvertising &&
            mode == lastAdvertisedMode &&
            lastAdvertisedDigest != null &&
            Arrays.equals(digest, lastAdvertisedDigest)
        ) {
            return
        }

        stopAdvertisingSafe()

        val advertiser = getBluetoothAdapter()?.bluetoothLeAdvertiser ?: return
        val (advMode, txPower) = when (mode) {
            MODE_SOS_EMERGENCY -> Pair(
                AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY,
                AdvertiseSettings.ADVERTISE_TX_POWER_HIGH,
            )

            MODE_SOS_SUSTAINED -> Pair(
                AdvertiseSettings.ADVERTISE_MODE_BALANCED,
                AdvertiseSettings.ADVERTISE_TX_POWER_HIGH,
            )

            MODE_GROUP_NORMAL -> Pair(
                AdvertiseSettings.ADVERTISE_MODE_BALANCED,
                AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM,
            )

            else -> Pair(
                AdvertiseSettings.ADVERTISE_MODE_LOW_POWER,
                AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM,
            )
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(advMode)
            .setTxPowerLevel(txPower)
            .setConnectable(true)
            .setTimeout(0)
            .build()

        // Primary Adv PDU: Flags (3B) + 128-bit Service UUID (18B) = 21B <= 31B legacy limit.
        val primaryData = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        // Scan Response PDU: 16-bit ServiceData 0x7A4E (4B header + 8B digest = 12B <= 31B).
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceData(SERVICE_DATA_UUID, digest)
            .build()

        try {
            advertiser.startAdvertising(settings, primaryData, scanResponse, advertiseCallback)
            activeAdvertiser = advertiser
            isAdvertising = true
            lastAdvertisedMode = mode
            lastAdvertisedDigest = digest
        } catch (e: SecurityException) {
            Log.w(TAG, "SecurityException starting BLE advertiser", e)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "IllegalStateException starting BLE advertiser", e)
        } catch (e: Exception) {
            Log.w(TAG, "Failed starting BLE advertiser", e)
        }
    }

    private fun stopAdvertisingSafe() {
        val advertiser = activeAdvertiser ?: getBluetoothAdapter()?.bluetoothLeAdvertiser
        if (isAdvertising && advertiser != null) {
            try {
                advertiser.stopAdvertising(advertiseCallback)
            } catch (_: SecurityException) {
            } catch (_: IllegalStateException) {
            } catch (_: Exception) {
            }
        }
        activeAdvertiser = null
        isAdvertising = false
        lastAdvertisedMode = null
        lastAdvertisedDigest = null
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            isAdvertising = true
        }

        override fun onStartFailure(errorCode: Int) {
            if (errorCode != ADVERTISE_FAILED_ALREADY_STARTED) {
                isAdvertising = false
                Log.w(TAG, "BLE advertising start failed with code=$errorCode")
            }
        }
    }

    // -------------------------------------------------------------------------
    // 3) Central BLE Scanner (Service UUID + Apple 0x004C Overflow Filter)
    // -------------------------------------------------------------------------

    private fun targetScanModeFor(mode: String): Int {
        return when (mode) {
            MODE_SOS_EMERGENCY -> ScanSettings.SCAN_MODE_LOW_LATENCY
            MODE_GROUP_NORMAL, MODE_SOS_SUSTAINED -> ScanSettings.SCAN_MODE_BALANCED
            else -> ScanSettings.SCAN_MODE_LOW_POWER
        }
    }

    private fun ensureScannerMatchingMode() {
        if (!isRunning || !hasBlePermissions() || !isAdapterOn()) return
        val desiredScanMode = targetScanModeFor(currentMode)
        if (isScanning && activeScanMode == desiredScanMode) {
            return
        }

        // Guard against Android 7.0+ AppScanStats 5-starts-per-30s throttling penalty.
        val nowElapsed = SystemClock.elapsedRealtime()
        val elapsedSinceLastStart = nowElapsed - lastScanStartElapsedMs
        if (lastScanStartElapsedMs > 0L && elapsedSinceLastStart < MIN_SCAN_RESTART_INTERVAL_MS) {
            if (pendingScanRestartRunnable == null) {
                val delayMs = (MIN_SCAN_RESTART_INTERVAL_MS - elapsedSinceLastStart).coerceAtLeast(250L)
                val runnable = Runnable {
                    pendingScanRestartRunnable = null
                    ensureScannerMatchingMode()
                }
                pendingScanRestartRunnable = runnable
                mainHandler.postDelayed(runnable, delayMs)
            }
            return
        }

        stopScannerSafe()

        val scanner = getBluetoothAdapter()?.bluetoothLeScanner ?: return
        val filters = listOf(
            // Filter 1: Explicit Wanderer 128-bit Service UUID (Android + foreground iOS).
            ScanFilter.Builder()
                .setServiceUuid(ParcelUuid(SERVICE_UUID))
                .build(),
            // Filter 2: Apple Company ID 0x004C Overflow Area type 0x01 (screen-locked iPhones).
            ScanFilter.Builder()
                .setManufacturerData(
                    APPLE_COMPANY_ID,
                    byteArrayOf(0x01),
                    byteArrayOf(0xFF.toByte()),
                )
                .build(),
        )

        val settings = ScanSettings.Builder()
            .setScanMode(desiredScanMode)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
            .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
            .setReportDelay(0L)
            .build()

        try {
            scanner.startScan(filters, settings, scanCallback)
            activeScanner = scanner
            isScanning = true
            activeScanMode = desiredScanMode
            lastScanStartElapsedMs = SystemClock.elapsedRealtime()
        } catch (e: SecurityException) {
            Log.w(TAG, "SecurityException starting BLE scan", e)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "IllegalStateException starting BLE scan", e)
        } catch (e: Exception) {
            Log.w(TAG, "Failed starting BLE scan", e)
        }
    }

    private fun stopScannerSafe() {
        val scanner = activeScanner ?: getBluetoothAdapter()?.bluetoothLeScanner
        if (isScanning && scanner != null) {
            try {
                scanner.stopScan(scanCallback)
            } catch (_: SecurityException) {
            } catch (_: IllegalStateException) {
            } catch (_: Exception) {
            }
        }
        activeScanner = null
        isScanning = false
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            mainHandler.post {
                handleScanResultOnMain(result)
            }
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            val snapshot = results.toList()
            mainHandler.post {
                for (item in snapshot) {
                    handleScanResultOnMain(item)
                }
            }
        }

        override fun onScanFailed(errorCode: Int) {
            if (errorCode != SCAN_FAILED_ALREADY_STARTED) {
                isScanning = false
                Log.w(TAG, "BLE scan failed with code=$errorCode")
            }
        }
    }

    private fun handleScanResultOnMain(result: ScanResult) {
        if (!isRunning || !hasBlePermissions() || !isAdapterOn()) return

        val device = result.device ?: return
        val address = device.address ?: return
        val rawRssi = result.rssi
        if (rawRssi < MIN_VALID_RSSI_DBM) return
        val rssi = if (rawRssi in -126..0) rawRssi else DEFAULT_GATT_WRITE_RSSI
        peerLastRssi[address] = rssi

        val record = result.scanRecord
        val hasExplicitServiceUuid =
            record?.serviceUuids?.contains(ParcelUuid(SERVICE_UUID)) == true
        val peerDigest = record?.getServiceData(SERVICE_DATA_UUID)
        val isExplicitWandererPeer = hasExplicitServiceUuid || peerDigest != null

        val nowElapsed = SystemClock.elapsedRealtime()

        if (isExplicitWandererPeer) {
            negativeAppleCache.remove(address)

            val existingSession = peerSessions[address]
            if (existingSession != null) {
                // If already connected in keep-alive mode and the peer's advertised digest changed,
                // read CHAR_SYNC_READ_UUID directly over the existing link without reconnecting!
                if (existingSession.handshakeComplete && !existingSession.closing &&
                    peerDigest != null && peerDigest.size >= DIGEST_LENGTH_BYTES &&
                    !Arrays.equals(peerLastSyncedDigest[address], peerDigest)
                ) {
                    existingSession.probedDigest = peerDigest.copyOf()
                    val syncChar = existingSession.syncReadChar
                    if (syncChar != null) {
                        enqueueSessionOp(existingSession, GattClientOp.ReadSync(syncChar))
                    }
                }
                return
            }

            if (peerDigest != null && peerDigest.size >= DIGEST_LENGTH_BYTES) {
                val flags = peerDigest[0].toInt() and 0xFF
                val peerEmpty = flags == 0 && peerDigest.all { it == 0.toByte() }
                val prevSynced = peerLastSyncedDigest[address]
                val digestUnchanged = prevSynced != null && Arrays.equals(prevSynced, peerDigest)
                val weNeedToPush = hasUnsyncedOutboundForPeer(address)

                // Zero-energy fast-path: skip GATT connection when peer has nothing new and
                // we have nothing new to push to it.
                if ((peerEmpty || digestUnchanged) && !weNeedToPush) {
                    return
                }
            }

            val cooldownMs = when (currentMode) {
                MODE_SOS_EMERGENCY -> if (peerDigest != null) 4_000L else 6_000L
                MODE_GROUP_NORMAL, MODE_SOS_SUSTAINED -> if (peerDigest != null) 6_000L else 10_000L
                else -> 15_000L
            }
            val lastAttempt = peerLastConnectAttemptMs[address] ?: 0L
            if (lastAttempt > 0L && nowElapsed - lastAttempt < cooldownMs) {
                return
            }

            if (peerSessions.size >= MAX_CONCURRENT_GATT_CLIENTS) {
                return
            }

            connectToPeerOnMain(
                device = device,
                probedDigest = peerDigest?.copyOf(),
                isAppleOverflowProbe = false,
            )
            return
        }

        // Apple 0x004C Overflow candidate (screen-locked iPhone).
        if (rssi < MIN_APPLE_OVERFLOW_PROBE_RSSI_DBM) {
            return
        }

        pruneExpiredNegativeAppleCache(nowElapsed)
        if (negativeAppleCache.containsKey(address)) {
            return
        }

        if (peerSessions.containsKey(address)) {
            return
        }

        val isKnownWandererIos = knownWandererApplePeers.containsKey(address)
        val cooldownMs = if (isKnownWandererIos) {
            when (currentMode) {
                MODE_SOS_EMERGENCY -> 6_000L
                MODE_GROUP_NORMAL, MODE_SOS_SUSTAINED -> 12_000L
                else -> 25_000L
            }
        } else {
            UNKNOWN_APPLE_PROBE_COOLDOWN_MS
        }

        val lastAttempt = peerLastConnectAttemptMs[address] ?: 0L
        if (lastAttempt > 0L && nowElapsed - lastAttempt < cooldownMs) {
            return
        }

        // Limit unknown Apple probes to 1 in-flight at a time so surrounding non-Wanderer
        // iPhones/AirPods never starve real Wanderer GATT slots.
        if (!isKnownWandererIos && peerSessions.values.any { it.isAppleOverflowProbe && !it.handshakeComplete }) {
            return
        }

        if (peerSessions.size >= MAX_CONCURRENT_GATT_CLIENTS) {
            return
        }

        connectToPeerOnMain(
            device = device,
            probedDigest = null,
            isAppleOverflowProbe = true,
        )
    }

    private fun pruneExpiredNegativeAppleCache(nowElapsed: Long) {
        if (negativeAppleCache.isEmpty()) return
        val iterator = negativeAppleCache.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            if (nowElapsed - entry.value > NEGATIVE_APPLE_CACHE_TTL_MS) {
                iterator.remove()
            }
        }
    }

    private fun hasUnsyncedOutboundForPeer(address: String): Boolean {
        if (localSyncBuffer.size <= 1) return false
        val currentDigest = localSyncDigest
        val lastPushed = peerLastPushedDigest[address] ?: return true
        return !Arrays.equals(lastPushed, currentDigest)
    }

    // -------------------------------------------------------------------------
    // 4) Sequential GATT Client State Machine (MTU 185 -> Read Sync -> Subscribe -> Push)
    // -------------------------------------------------------------------------

    private sealed class GattClientOp {
        data class ReadSync(val characteristic: BluetoothGattCharacteristic) : GattClientOp()
        data class SubscribeIngress(val characteristic: BluetoothGattCharacteristic) : GattClientOp()
        data class WriteIngress(
            val characteristic: BluetoothGattCharacteristic,
            val frameBytes: ByteArray,
            val markDigest: ByteArray?,
        ) : GattClientOp()
    }

    private class PeerGattSession(
        val address: String,
        var probedDigest: ByteArray?,
        val isAppleOverflowProbe: Boolean,
    ) {
        var gatt: BluetoothGatt? = null
        var syncReadChar: BluetoothGattCharacteristic? = null
        var ingressChar: BluetoothGattCharacteristic? = null
        val opQueue = ArrayDeque<GattClientOp>()
        var currentOp: GattClientOp? = null
        var handshakeComplete = false
        var isSubscribed = false
        var closing = false
        var timeoutRunnable: Runnable? = null
    }

    private fun shouldKeepAliveClientLink(): Boolean {
        return currentMode == MODE_SOS_EMERGENCY ||
            currentMode == MODE_SOS_SUSTAINED ||
            currentMode == MODE_GROUP_NORMAL
    }

    private fun connectToPeerOnMain(
        device: BluetoothDevice,
        probedDigest: ByteArray?,
        isAppleOverflowProbe: Boolean,
    ) {
        val ctx = appContext ?: return
        val address = device.address ?: return
        peerLastConnectAttemptMs[address] = SystemClock.elapsedRealtime()

        val session = PeerGattSession(
            address = address,
            probedDigest = probedDigest,
            isAppleOverflowProbe = isAppleOverflowProbe,
        )
        peerSessions[address] = session

        val timeoutRunnable = Runnable {
            if (!session.handshakeComplete) {
                disconnectAndCloseSessionOnMain(session)
            }
        }
        session.timeoutRunnable = timeoutRunnable
        mainHandler.postDelayed(timeoutRunnable, GATT_HANDSHAKE_TIMEOUT_MS)

        try {
            val gatt = device.connectGatt(
                ctx,
                false,
                createGattClientCallback(session),
                BluetoothDevice.TRANSPORT_LE,
            )
            if (gatt == null) {
                closePeerSessionImmediate(session)
            } else {
                session.gatt = gatt
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "SecurityException connecting GATT to $address", e)
            closePeerSessionImmediate(session)
        } catch (e: Exception) {
            Log.w(TAG, "Failed connecting GATT to $address", e)
            closePeerSessionImmediate(session)
        }
    }

    private fun createGattClientCallback(session: PeerGattSession): BluetoothGattCallback {
        return object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                mainHandler.post {
                    if (newState == BluetoothProfile.STATE_CONNECTED &&
                        status == BluetoothGatt.GATT_SUCCESS &&
                        !session.closing &&
                        isRunning
                    ) {
                        val mtuRequested = runCatching { gatt.requestMtu(TARGET_GATT_MTU) }
                            .getOrDefault(false)
                        if (!mtuRequested) {
                            runCatching { gatt.discoverServices() }
                                .onFailure { disconnectAndCloseSessionOnMain(session) }
                        }
                    } else if (newState == BluetoothProfile.STATE_DISCONNECTED ||
                        status != BluetoothGatt.GATT_SUCCESS
                    ) {
                        closePeerSessionImmediate(session)
                    }
                }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                mainHandler.post {
                    if (session.closing || !isRunning) return@post
                    val started = runCatching { gatt.discoverServices() }.getOrDefault(false)
                    if (!started) {
                        disconnectAndCloseSessionOnMain(session)
                    }
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                mainHandler.post {
                    if (session.closing || !isRunning) return@post
                    if (status != BluetoothGatt.GATT_SUCCESS) {
                        disconnectAndCloseSessionOnMain(session)
                        return@post
                    }

                    val service = gatt.getService(SERVICE_UUID)
                    if (service == null) {
                        // Non-Wanderer peripheral (e.g., ordinary locked iPhone or AirPods):
                        // cache negative MAC for 15 minutes so we never probe it again.
                        if (session.isAppleOverflowProbe) {
                            negativeAppleCache[session.address] = SystemClock.elapsedRealtime()
                            knownWandererApplePeers.remove(session.address)
                        }
                        disconnectAndCloseSessionOnMain(session)
                        return@post
                    }

                    negativeAppleCache.remove(session.address)
                    if (session.isAppleOverflowProbe) {
                        knownWandererApplePeers[session.address] = SystemClock.elapsedRealtime()
                    }

                    val syncReadChar = service.getCharacteristic(CHAR_SYNC_READ_UUID)
                    val ingressChar = service.getCharacteristic(CHAR_MESH_INGRESS_UUID)
                    session.syncReadChar = syncReadChar
                    session.ingressChar = ingressChar

                    if (syncReadChar != null) {
                        session.opQueue.addLast(GattClientOp.ReadSync(syncReadChar))
                    }

                    if (ingressChar != null && shouldKeepAliveClientLink() && !session.isSubscribed) {
                        val props = ingressChar.properties
                        if ((props and BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0) {
                            session.opQueue.addLast(GattClientOp.SubscribeIngress(ingressChar))
                        }
                    }

                    if (ingressChar != null && hasUnsyncedOutboundForPeer(session.address)) {
                        val frames = unpackFramesFromSyncBuffer(localSyncBuffer)
                        val digestSnapshot = localSyncDigest.copyOf()
                        for ((idx, frame) in frames.withIndex()) {
                            val mark = if (idx == frames.lastIndex) digestSnapshot else null
                            session.opQueue.addLast(
                                GattClientOp.WriteIngress(ingressChar, frame, mark),
                            )
                        }
                    }

                    pumpNextGattOpOnMain(session)
                }
            }

            @TargetApi(Build.VERSION_CODES.TIRAMISU)
            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
                status: Int,
            ) {
                val copy = value.copyOf()
                mainHandler.post {
                    onClientCharacteristicReadOnMain(session, characteristic.uuid, copy, status)
                }
            }

            @Suppress("DEPRECATION")
            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
                val copy = characteristic.value?.copyOf() ?: ByteArray(0)
                mainHandler.post {
                    onClientCharacteristicReadOnMain(session, characteristic.uuid, copy, status)
                }
            }

            override fun onDescriptorWrite(
                gatt: BluetoothGatt,
                descriptor: BluetoothGattDescriptor,
                status: Int,
            ) {
                mainHandler.post {
                    if (session.closing) return@post
                    if (session.currentOp is GattClientOp.SubscribeIngress) {
                        session.isSubscribed = (status == BluetoothGatt.GATT_SUCCESS)
                        session.currentOp = null
                        pumpNextGattOpOnMain(session)
                    }
                }
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                mainHandler.post {
                    if (session.closing) return@post
                    val op = session.currentOp
                    if (op is GattClientOp.WriteIngress) {
                        if (status == BluetoothGatt.GATT_SUCCESS && op.markDigest != null) {
                            peerLastPushedDigest[session.address] = op.markDigest
                        }
                        session.currentOp = null
                        pumpNextGattOpOnMain(session)
                    }
                }
            }

            @TargetApi(Build.VERSION_CODES.TIRAMISU)
            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
            ) {
                if (characteristic.uuid != CHAR_MESH_INGRESS_UUID || value.isEmpty()) return
                val copy = value.copyOf()
                val rssi = peerLastRssi[session.address] ?: DEFAULT_GATT_WRITE_RSSI
                emitEvent(
                    mapOf(
                        "type" to "frame",
                        "bytes" to copy,
                        "rssi" to rssi,
                        "peerId" to session.address,
                    ),
                )
            }

            @Suppress("DEPRECATION")
            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
            ) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
                if (characteristic.uuid != CHAR_MESH_INGRESS_UUID) return
                val raw = characteristic.value ?: return
                if (raw.isEmpty()) return
                val copy = raw.copyOf()
                val rssi = peerLastRssi[session.address] ?: DEFAULT_GATT_WRITE_RSSI
                emitEvent(
                    mapOf(
                        "type" to "frame",
                        "bytes" to copy,
                        "rssi" to rssi,
                        "peerId" to session.address,
                    ),
                )
            }
        }
    }

    private fun onClientCharacteristicReadOnMain(
        session: PeerGattSession,
        charUuid: UUID,
        bytes: ByteArray,
        status: Int,
    ) {
        if (session.closing) return
        if (charUuid == CHAR_SYNC_READ_UUID) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                session.probedDigest?.let { peerLastSyncedDigest[session.address] = it }
                if (bytes.isNotEmpty()) {
                    val rssi = peerLastRssi[session.address] ?: DEFAULT_GATT_WRITE_RSSI
                    emitEvent(
                        mapOf(
                            "type" to "syncBuffer",
                            "bytes" to bytes,
                            "rssi" to rssi,
                            "peerId" to session.address,
                        ),
                    )
                }
            }
            if (session.currentOp is GattClientOp.ReadSync) {
                session.currentOp = null
                pumpNextGattOpOnMain(session)
            }
        }
    }

    private fun enqueueSessionOp(session: PeerGattSession, op: GattClientOp) {
        if (session.closing) return
        session.opQueue.addLast(op)
        if (session.currentOp == null && session.handshakeComplete) {
            pumpNextGattOpOnMain(session)
        }
    }

    private fun pumpNextGattOpOnMain(session: PeerGattSession) {
        if (session.closing || !isRunning) {
            disconnectAndCloseSessionOnMain(session)
            return
        }
        val gatt = session.gatt
        if (gatt == null) {
            closePeerSessionImmediate(session)
            return
        }

        while (session.currentOp == null) {
            val next = session.opQueue.removeFirstOrNull() ?: break
            session.currentOp = next
            val started = executeGattOp(gatt, next)
            if (!started) {
                session.currentOp = null
            }
        }

        if (session.currentOp == null && session.opQueue.isEmpty()) {
            session.timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
            session.timeoutRunnable = null
            session.handshakeComplete = true

            val keepAliveCount = peerSessions.values.count { it.handshakeComplete && !it.closing }
            val keepOpen = shouldKeepAliveClientLink() && keepAliveCount <= MAX_KEEPALIVE_CLIENTS
            if (!keepOpen) {
                disconnectAndCloseSessionOnMain(session)
            }
        }
    }

    private fun executeGattOp(gatt: BluetoothGatt, op: GattClientOp): Boolean {
        return try {
            when (op) {
                is GattClientOp.ReadSync -> {
                    gatt.readCharacteristic(op.characteristic)
                }

                is GattClientOp.SubscribeIngress -> {
                    val notifySet = gatt.setCharacteristicNotification(op.characteristic, true)
                    val cccd = op.characteristic.getDescriptor(CCCD_UUID)
                    if (!notifySet || cccd == null) {
                        false
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        gatt.writeDescriptor(
                            cccd,
                            BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE,
                        ) == BluetoothStatusCodes.SUCCESS
                    } else {
                        @Suppress("DEPRECATION")
                        cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                        @Suppress("DEPRECATION")
                        gatt.writeDescriptor(cccd)
                    }
                }

                is GattClientOp.WriteIngress -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        gatt.writeCharacteristic(
                            op.characteristic,
                            op.frameBytes,
                            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE,
                        ) == BluetoothStatusCodes.SUCCESS
                    } else {
                        @Suppress("DEPRECATION")
                        op.characteristic.writeType =
                            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                        @Suppress("DEPRECATION")
                        op.characteristic.value = op.frameBytes
                        @Suppress("DEPRECATION")
                        gatt.writeCharacteristic(op.characteristic)
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed executing GATT client operation", e)
            false
        }
    }

    private fun pushFrameToConnectedPeripherals(frameBytes: ByteArray, digestSnapshot: ByteArray) {
        if (peerSessions.isEmpty()) return
        val copy = frameBytes.copyOf()
        mainHandler.post {
            for (session in peerSessions.values.toList()) {
                val ingress = session.ingressChar
                if (!session.closing && session.handshakeComplete && ingress != null) {
                    enqueueSessionOp(
                        session,
                        GattClientOp.WriteIngress(ingress, copy, digestSnapshot.copyOf()),
                    )
                }
            }
        }
    }

    private fun disconnectAndCloseSessionOnMain(session: PeerGattSession) {
        if (session.closing) return
        session.closing = true
        session.timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        session.timeoutRunnable = null
        session.opQueue.clear()
        session.currentOp = null

        val gatt = session.gatt
        if (gatt == null) {
            peerSessions.remove(session.address, session)
            return
        }

        try {
            gatt.disconnect()
        } catch (_: Exception) {
        }

        // Ensure clientIf slot is released promptly even if remote peer walked out of range.
        mainHandler.postDelayed(
            { closePeerSessionImmediate(session) },
            GATT_DISCONNECT_GRACE_MS,
        )
    }

    private fun closePeerSessionImmediate(session: PeerGattSession) {
        session.closing = true
        session.timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        session.timeoutRunnable = null
        session.opQueue.clear()
        session.currentOp = null

        val gatt = session.gatt
        session.gatt = null
        peerSessions.remove(session.address, session)
        if (gatt != null) {
            try {
                gatt.close()
            } catch (_: SecurityException) {
            } catch (_: IllegalStateException) {
            } catch (_: Exception) {
            }
        }
    }

    private fun closeAllGattClientsSafe() {
        val sessions = peerSessions.values.toList()
        peerSessions.clear()
        for (session in sessions) {
            session.closing = true
            session.timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
            session.timeoutRunnable = null
            session.opQueue.clear()
            session.currentOp = null
            val gatt = session.gatt
            session.gatt = null
            if (gatt != null) {
                try {
                    gatt.disconnect()
                } catch (_: Exception) {
                }
                try {
                    gatt.close()
                } catch (_: Exception) {
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Payload Helpers
    // -------------------------------------------------------------------------

    private fun normalizeMode(raw: String?): String {
        val cleaned = raw?.trim()?.lowercase() ?: return MODE_PASSIVE_GUARD
        if (cleaned.isEmpty()) return MODE_PASSIVE_GUARD
        return when {
            cleaned == MODE_SOS_SUSTAINED || cleaned.contains("sustained") -> MODE_SOS_SUSTAINED
            cleaned.contains("sos") -> MODE_SOS_EMERGENCY
            cleaned.contains("group") -> MODE_GROUP_NORMAL
            cleaned.contains("idle") || cleaned == "off" -> MODE_IDLE_OFF
            else -> MODE_PASSIVE_GUARD
        }
    }

    private fun extractBytes(raw: Any?): ByteArray? {
        return when (raw) {
            is ByteArray -> raw
            is List<*> -> {
                val out = ByteArray(raw.size)
                for (i in raw.indices) {
                    val num = raw[i] as? Number ?: return null
                    out[i] = num.toByte()
                }
                out
            }
            else -> null
        }
    }

    private fun normalizeDigest8B(raw: ByteArray?): ByteArray {
        val out = ByteArray(DIGEST_LENGTH_BYTES)
        if (raw != null && raw.isNotEmpty()) {
            System.arraycopy(raw, 0, out, 0, minOf(raw.size, DIGEST_LENGTH_BYTES))
        }
        return out
    }

    private fun clampSyncBuffer(raw: ByteArray?): ByteArray {
        if (raw == null || raw.isEmpty()) return ByteArray(0)
        return if (raw.size <= MAX_SYNC_BUFFER_BYTES) {
            raw.copyOf()
        } else {
            raw.copyOfRange(0, MAX_SYNC_BUFFER_BYTES)
        }
    }

    /**
     * Unpacks individual v1 frames (`[0x54, pktType, ttlHops, bodyLen, ...]`) from a packed
     * sync buffer (`[frameCount, frame1, frame2, ...]`) so Central connections to screen-locked
     * peers can push unsynced frames directly to `CHAR_MESH_INGRESS_UUID`.
     */
    private fun unpackFramesFromSyncBuffer(buffer: ByteArray): List<ByteArray> {
        if (buffer.isEmpty()) return emptyList()

        // Single raw frame fallback (`magicVer == 0x54`).
        val firstByte = buffer[0].toInt() and 0xFF
        if (firstByte == PACKET_MAGIC_V1 && buffer.size >= MIN_FRAME_BYTES) {
            val singleBodyLen = buffer[3].toInt() and 0xFF
            val singleFrameLen = 4 + singleBodyLen
            if (singleFrameLen in MIN_FRAME_BYTES..MAX_FRAME_BYTES && singleFrameLen == buffer.size) {
                return listOf(buffer.copyOf())
            }
        }

        if (buffer.size <= 1 || firstByte == 0) return emptyList()

        val frames = ArrayList<ByteArray>(minOf(firstByte, 8))
        var offset = 1
        while (offset + 4 <= buffer.size && frames.size < firstByte) {
            val magic = buffer[offset].toInt() and 0xFF
            if (magic != PACKET_MAGIC_V1) break
            val bodyLen = buffer[offset + 3].toInt() and 0xFF
            val frameLen = 4 + bodyLen
            if (frameLen < MIN_FRAME_BYTES || frameLen > MAX_FRAME_BYTES) break
            if (offset + frameLen > buffer.size) break
            frames.add(buffer.copyOfRange(offset, offset + frameLen))
            offset += frameLen
        }
        return frames
    }

    companion object {
        private const val TAG = "BleProximityPlugin"

        private const val METHOD_CHANNEL_NAME = "com.openwanderer.wanderer/ble_proximity"
        private const val EVENT_CHANNEL_NAME = "com.openwanderer.wanderer/ble_proximity/events"

        private const val REQ_BLE_PERMISSIONS = 7419

        private const val MODE_IDLE_OFF = "idle_off"
        private const val MODE_PASSIVE_GUARD = "passive_guard"
        private const val MODE_GROUP_NORMAL = "group_normal"
        private const val MODE_SOS_EMERGENCY = "sos_emergency"
        private const val MODE_SOS_SUSTAINED = "sos_sustained"

        private val SERVICE_UUID: UUID =
            UUID.fromString("7a4e0001-8c3b-4f2d-9e1a-5b6c7d8e9f00")
        private val SERVICE_DATA_UUID: ParcelUuid =
            ParcelUuid.fromString("00007a4e-0000-1000-8000-00805f9b34fb")
        private val CHAR_SYNC_READ_UUID: UUID =
            UUID.fromString("7a4e0002-8c3b-4f2d-9e1a-5b6c7d8e9f00")
        private val CHAR_MESH_INGRESS_UUID: UUID =
            UUID.fromString("7a4e0003-8c3b-4f2d-9e1a-5b6c7d8e9f00")
        private val CCCD_UUID: UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        private const val APPLE_COMPANY_ID = 0x004C
        private const val DIGEST_LENGTH_BYTES = 8
        private const val MAX_SYNC_BUFFER_BYTES = 180
        private const val TARGET_GATT_MTU = 185

        private const val PACKET_MAGIC_V1 = 0x54
        private const val MIN_FRAME_BYTES = 30
        private const val MAX_FRAME_BYTES = 88

        private const val DEFAULT_GATT_WRITE_RSSI = -65
        private const val MIN_VALID_RSSI_DBM = -96
        private const val MIN_APPLE_OVERFLOW_PROBE_RSSI_DBM = -88

        private const val MIN_SCAN_RESTART_INTERVAL_MS = 7_000L
        private const val NEGATIVE_APPLE_CACHE_TTL_MS = 15L * 60L * 1000L
        private const val UNKNOWN_APPLE_PROBE_COOLDOWN_MS = 30_000L
        private const val GATT_HANDSHAKE_TIMEOUT_MS = 10_000L
        private const val GATT_DISCONNECT_GRACE_MS = 600L

        private const val MAX_CONCURRENT_GATT_CLIENTS = 4
        private const val MAX_KEEPALIVE_CLIENTS = 3
    }
}
