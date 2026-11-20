package studio.orb.orb_mobile

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings

internal class OrbOverlaySettings(private val context: Context) {
    private val prefs = context.getSharedPreferences("orb_overlay", Context.MODE_PRIVATE)
    val overlayGranted
        get() = Settings.canDrawOverlays(context)

    val micGranted
        get() =
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED

    var enabled: Boolean
        get() = prefs.getBoolean("enabled", false)
        set(value) {
            prefs.edit().putBoolean("enabled", value).apply()
        }

    val size
        get() = prefs.getFloat("size", 48f)

    val opacity
        get() = prefs.getFloat("opacity", .92f)

    val snap
        get() = prefs.getBoolean("snap", true)

    val tap
        get() = prefs.getString("tap", "panel") ?: "panel"

    val doubleTap
        get() = prefs.getString("doubleTap", "open") ?: "open"

    val hold
        get() = prefs.getString("hold", "voice") ?: "voice"

    val voiceEnabled
        get() = hold != "none"

    val canRun
        get() = overlayGranted && (!voiceEnabled || micGranted)

    fun markConversationChanged() {
        prefs.edit().putBoolean("conversationChanged", true).apply()
    }

    fun consumeConversationChanged(): Boolean {
        val changed = prefs.getBoolean("conversationChanged", false)
        if (changed) prefs.edit().remove("conversationChanged").apply()
        return changed
    }

    val xFraction
        get() = prefs.getFloat("posX", 1f)

    val yFraction
        get() = prefs.getFloat("posY", .52f)

    fun savePosition(x: Float, y: Float) {
        prefs
            .edit()
            .putFloat("posX", x.coerceIn(0f, 1f))
            .putFloat("posY", y.coerceIn(0f, 1f))
            .apply()
    }

    fun snapshot(): Map<String, Any> =
        mapOf(
            "enabled" to enabled,
            "running" to (OrbOverlayService.current != null),
            "overlayGranted" to overlayGranted,
            "micGranted" to micGranted,
            "size" to size.toDouble(),
            "opacity" to opacity.toDouble(),
            "snap" to snap,
            "tap" to tap,
            "doubleTap" to doubleTap,
            "hold" to hold,
        )

    fun save(values: Map<*, *>) {
        val editor = prefs.edit()
        (values["size"] as? Number)
            ?.toFloat()
            ?.takeIf { it.isFinite() }
            ?.let { editor.putFloat("size", it.coerceIn(44f, 80f)) }
        (values["opacity"] as? Number)
            ?.toFloat()
            ?.takeIf { it.isFinite() }
            ?.let { editor.putFloat("opacity", it.coerceIn(.35f, 1f)) }
        (values["snap"] as? Boolean)?.let { editor.putBoolean("snap", it) }
        for (key in listOf("tap", "doubleTap", "hold")) {
            val value = values[key] as? String ?: continue
            val allowed =
                if (key == "hold") setOf("voice", "newVoice", "none")
                else setOf("panel", "open", "read", "stop", "none")
            if (key == "hold" && value != "none" && enabled) {
                check(micGranted) { "请先允许麦克风以使用长按语音。" }
            }
            require(value in allowed) { "未知的悬浮球操作。" }
            editor.putString(key, value)
        }
        editor.apply()
    }
}
