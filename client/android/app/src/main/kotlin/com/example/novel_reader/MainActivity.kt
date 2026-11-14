package com.example.novel_reader
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var active = false
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "reader/hardware").also { ch ->
            ch.setMethodCallHandler { call, result ->
                if(call.method == "volume") { active = call.arguments == true; result.success(null) } else if(call.method=="battery"){val battery=getSystemService(BATTERY_SERVICE) as android.os.BatteryManager;result.success(battery.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY))} else result.notImplemented()
            }
        }
    }
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if(active && (event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || event.keyCode == KeyEvent.KEYCODE_VOLUME_UP)) {
            if(event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) channel?.invokeMethod("turn", if(event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) 1 else -1)
            return true
        }
        return super.dispatchKeyEvent(event)
    }
}
