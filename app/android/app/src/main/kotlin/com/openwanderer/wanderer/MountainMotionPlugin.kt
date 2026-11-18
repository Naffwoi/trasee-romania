package com.openwanderer.wanderer

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.TriggerEvent
import android.hardware.TriggerEventListener
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.sqrt

/**
 * Permissionless hardware motion & battery telemetry plugin for Adaptive Mountain
 * Battery Saver ("Stationary Sleep").
 *
 * Uses ONLY `Sensor.TYPE_ACCELEROMETER` (batched 5s FIFO) while moving and
 * `Sensor.TYPE_SIGNIFICANT_MOTION` (0.08 mW DSP wake-up trigger) while asleep —
 * requiring ZERO `ACTIVITY_RECOGNITION` or Google Play Health declarations.
 */
class MountainMotionPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    SensorEventListener {

    private var appContext: Context? = null
    private var sensorManager: SensorManager? = null
    private var accelSensor: Sensor? = null
    private var significantMotionSensor: Sensor? = null

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var accelRegistered = false
    private var sigMotionArmed = false
    private var wakeSentinelMode = false

    private val linearMagWindow = DoubleArray(WINDOW_CAPACITY)
    private var windowCount = 0
    private var windowWriteIdx = 0
    private var gravityEst = SensorManager.GRAVITY_EARTH.toDouble()
    private var lastSampleEmitElapsedMs = 0L
    private var consecutiveImpactSamples = 0

    private val significantTriggerListener = object : TriggerEventListener() {
        override fun onTrigger(event: TriggerEvent?) {
            sigMotionArmed = false
            emitOnMain(
                mapOf(
                    "kind" to "step_wake",
                    "stepBandVariance" to 1.5,
                    "isMovingHardware" to true,
                ),
            )
            // Transition back to batched step-variance monitoring after wake.
            startStepMonitoringInternal()
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx = binding.applicationContext
        appContext = ctx
        val sm = ctx.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        sensorManager = sm
        accelSensor = sm?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        significantMotionSensor = sm?.getDefaultSensor(Sensor.TYPE_SIGNIFICANT_MOTION)

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopAllInternal()
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
        sensorManager = null
        appContext = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startStepMonitoring" -> {
                val ok = startStepMonitoringInternal()
                result.success(ok)
            }
            "armStationaryWakeTrigger" -> {
                val ok = armStationaryWakeInternal()
                result.success(ok)
            }
            "stop" -> {
                stopAllInternal()
                result.success(true)
            }
            "getBatterySnapshot" -> {
                result.success(readBatterySnapshot())
            }
            else -> result.notImplemented()
        }
    }

    private fun startStepMonitoringInternal(): Boolean {
        val sm = sensorManager ?: return false
        cancelSignificantMotionSafe(sm)
        wakeSentinelMode = false
        resetWindow()
        val accel = accelSensor ?: return false
        if (!accelRegistered) {
            accelRegistered = sm.registerListener(
                this,
                accel,
                SensorManager.SENSOR_DELAY_NORMAL,
                BATCH_REPORT_LATENCY_US,
            )
        }
        return accelRegistered
    }

    private fun armStationaryWakeInternal(): Boolean {
        val sm = sensorManager ?: return false
        val sig = significantMotionSensor
        if (sig != null) {
            // Unregister continuous accelerometer so AP CPU can enter deep suspend;
            // DSP wake-up sensor triggers significantTriggerListener on walking motion.
            unregisterAccelSafe(sm)
            if (!sigMotionArmed) {
                sigMotionArmed = sm.requestTriggerSensor(significantTriggerListener, sig)
            }
            if (sigMotionArmed) {
                return true
            }
        }
        // Fallback for rare devices without TYPE_SIGNIFICANT_MOTION: keep low-rate
        // accelerometer in instant-wake sentinel mode.
        wakeSentinelMode = true
        consecutiveImpactSamples = 0
        val accel = accelSensor ?: return false
        if (!accelRegistered) {
            accelRegistered = sm.registerListener(
                this,
                accel,
                SensorManager.SENSOR_DELAY_NORMAL,
            )
        }
        return accelRegistered
    }

    private fun stopAllInternal() {
        val sm = sensorManager
        if (sm != null) {
            unregisterAccelSafe(sm)
            cancelSignificantMotionSafe(sm)
        }
        wakeSentinelMode = false
        resetWindow()
    }

    private fun unregisterAccelSafe(sm: SensorManager) {
        if (accelRegistered) {
            runCatching { sm.unregisterListener(this) }
            accelRegistered = false
        }
    }

    private fun cancelSignificantMotionSafe(sm: SensorManager) {
        val sig = significantMotionSensor
        if (sigMotionArmed && sig != null) {
            runCatching { sm.cancelTriggerSensor(significantTriggerListener, sig) }
        }
        sigMotionArmed = false
    }

    private fun resetWindow() {
        windowCount = 0
        windowWriteIdx = 0
        consecutiveImpactSamples = 0
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event?.sensor?.type != Sensor.TYPE_ACCELEROMETER || event.values.size < 3) return
        val ax = event.values[0].toDouble()
        val ay = event.values[1].toDouble()
        val az = event.values[2].toDouble()
        val mag = sqrt(ax * ax + ay * ay + az * az)

        // Low-pass gravity filter + high-pass footstep linear acceleration residual.
        gravityEst = 0.9 * gravityEst + 0.1 * mag
        val linear = mag - gravityEst

        if (wakeSentinelMode) {
            if (kotlin.math.abs(linear) >= FOOTSTEP_WAKE_ACCEL_MPS2) {
                consecutiveImpactSamples++
                if (consecutiveImpactSamples >= 2) {
                    wakeSentinelMode = false
                    consecutiveImpactSamples = 0
                    emitOnMain(
                        mapOf(
                            "kind" to "step_wake",
                            "stepBandVariance" to (linear * linear),
                            "isMovingHardware" to true,
                        ),
                    )
                }
            } else {
                consecutiveImpactSamples = 0
            }
            return
        }

        linearMagWindow[windowWriteIdx] = linear
        windowWriteIdx = (windowWriteIdx + 1) % WINDOW_CAPACITY
        if (windowCount < WINDOW_CAPACITY) windowCount++

        val nowElapsed = SystemClock.elapsedRealtime()
        if (windowCount >= 10 && nowElapsed - lastSampleEmitElapsedMs >= SAMPLE_EMIT_INTERVAL_MS) {
            lastSampleEmitElapsedMs = nowElapsed
            val variance = computeVariance()
            val moving = variance >= MOVING_VARIANCE_THRESHOLD
            emitOnMain(
                mapOf(
                    "kind" to "motion_sample",
                    "stepBandVariance" to variance,
                    "isMovingHardware" to moving,
                ),
            )
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun computeVariance(): Double {
        val n = windowCount
        if (n <= 1) return 0.0
        var sum = 0.0
        for (i in 0 until n) sum += linearMagWindow[i]
        val mean = sum / n
        var sq = 0.0
        for (i in 0 until n) {
            val d = linearMagWindow[i] - mean
            sq += d * d
        }
        return sq / n
    }

    private fun readBatterySnapshot(): Map<String, Any> {
        val ctx = appContext
        val bm = ctx?.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        val pm = ctx?.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val pct = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            ?.takeIf { it in 0..100 } ?: 100
        val lowPower = pm?.isPowerSaveMode == true
        return mapOf(
            "batteryPercent" to pct,
            "osLowPowerMode" to lowPower,
        )
    }

    private fun emitOnMain(payload: Map<String, Any>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventSink?.success(payload)
        } else {
            mainHandler.post { eventSink?.success(payload) }
        }
    }

    companion object {
        private const val METHOD_CHANNEL = "com.openwanderer.wanderer/mountain_motion"
        private const val EVENT_CHANNEL = "com.openwanderer.wanderer/mountain_motion/events"
        private const val BATCH_REPORT_LATENCY_US = 5_000_000 // 5s hardware sensor FIFO batch
        private const val SAMPLE_EMIT_INTERVAL_MS = 4_000L
        private const val WINDOW_CAPACITY = 25 // ~5s at SENSOR_DELAY_NORMAL (~5 Hz)
        private const val MOVING_VARIANCE_THRESHOLD = 0.035 // m^2/s^4
        private const val FOOTSTEP_WAKE_ACCEL_MPS2 = 1.15 // m/s^2
    }
}
