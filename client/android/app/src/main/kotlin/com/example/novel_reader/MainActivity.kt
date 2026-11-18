package com.example.novel_reader

import android.os.BatteryManager
import android.view.KeyEvent
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var active = false
    private var barsBehaviorBeforeReading: Int? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "reader/hardware").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "volume" -> {
                        active = call.arguments == true
                        result.success(null)
                    }
                    "battery" -> {
                        val battery = getSystemService(BATTERY_SERVICE) as BatteryManager
                        result.success(battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
                    }
                    "setSystemBarsHidden" -> {
                        setSystemBarsHidden(call.arguments == true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun setSystemBarsHidden(hidden: Boolean) {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        val bars = WindowInsetsCompat.Type.systemBars()
        if (hidden) {
            if (barsBehaviorBeforeReading == null) barsBehaviorBeforeReading = controller.systemBarsBehavior
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(bars)
        } else {
            controller.show(bars)
            barsBehaviorBeforeReading?.let { controller.systemBarsBehavior = it }
            barsBehaviorBeforeReading = null
        }
    }

    override fun onPostResume() {
        super.onPostResume()
        if (barsBehaviorBeforeReading != null) setSystemBarsHidden(true)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && barsBehaviorBeforeReading != null) setSystemBarsHidden(true)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if(active && (event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || event.keyCode == KeyEvent.KEYCODE_VOLUME_UP)) {
            if(event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) channel?.invokeMethod("turn", if(event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) 1 else -1)
            return true
        }
        return super.dispatchKeyEvent(event)
    }
}
