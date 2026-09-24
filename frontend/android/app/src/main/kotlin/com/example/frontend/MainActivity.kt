package com.example.frontend

import android.content.Context
import android.net.wifi.WifiManager
import android.os.PowerManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    private val LIFECYCLE_CHANNEL = "com.nasradio/lifecycle"
    private val KEEPALIVE_CHANNEL = "com.nasradio/castkeepalive"

    // Held while casting so locking the phone doesn't drop the LAN connection
    // to the TV. The foreground service keeps the CPU alive, but it does NOT
    // stop Wi-Fi from entering power-save when the screen turns off — which
    // dropped the cast within seconds of locking. A FULL_HIGH_PERF Wi-Fi lock
    // keeps the radio active across screen-off (LOW_LATENCY only works while
    // foreground, so it's the wrong mode here). The partial wake lock is
    // belt-and-suspenders for the CPU.
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LIFECYCLE_CHANNEL)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KEEPALIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        acquireLocks()
                        result.success(true)
                    }
                    "release" -> {
                        releaseLocks()
                        result.success(true)
                    }
                    "ensureBatteryExemption" -> {
                        result.success(ensureBatteryExemption())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        try {
            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                wifiLock = wm.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "NASRadio:castWifi"
                )
                wifiLock?.setReferenceCounted(false)
            }
            if (wifiLock?.isHeld == false) wifiLock?.acquire()

            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "NASRadio:castCpu"
                )
                wakeLock?.setReferenceCounted(false)
            }
            if (wakeLock?.isHeld == false) wakeLock?.acquire()
            android.util.Log.i("NASRadio", "cast keep-alive locks acquired")
        } catch (e: Exception) {
            android.util.Log.w("NASRadio", "acquireLocks failed: $e")
        }
    }

    // Doze is the cast-killer: while casting, the phone outputs no audio,
    // so after ~30-45 min stationary + screen-off Android suspends the
    // app's networking — wake locks and Wi-Fi locks are explicitly ignored
    // by Doze. (Aug 12 forensics: phone had ZERO network for ~10 min —
    // no LAN, no cellular — and recovered the instant the screen woke.)
    // Battery-optimization exemption is the sanctioned escape hatch.
    // Returns true if already exempt; otherwise fires the one-time system
    // prompt and returns false (exempt on the NEXT cast if user allows).
    private fun ensureBatteryExemption(): Boolean {
        return try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (pm.isIgnoringBatteryOptimizations(packageName)) {
                android.util.Log.i("NASRadio", "battery optimization: already exempt")
                true
            } else {
                android.util.Log.i("NASRadio", "battery optimization: not exempt — prompting")
                val intent = android.content.Intent(
                    android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    android.net.Uri.parse("package:$packageName")
                )
                startActivity(intent)
                false
            }
        } catch (e: Exception) {
            android.util.Log.w("NASRadio", "ensureBatteryExemption failed: $e")
            false
        }
    }

    private fun releaseLocks() {
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
            if (wakeLock?.isHeld == true) wakeLock?.release()
            android.util.Log.i("NASRadio", "cast keep-alive locks released")
        } catch (e: Exception) {
            android.util.Log.w("NASRadio", "releaseLocks failed: $e")
        }
    }

    override fun onDestroy() {
        // App swiped away — never leave the locks held.
        releaseLocks()
        val audioServiceIntent = android.content.Intent(this, com.ryanheise.audioservice.AudioService::class.java)
        stopService(audioServiceIntent)
        super.onDestroy()
    }
}
