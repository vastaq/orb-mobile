package studio.orb.orb_mobile

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val settings by lazy { OrbOverlaySettings(this) }
    private var overlayApproval: MethodChannel.Result? = null
    private var micApproval: MethodChannel.Result? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        engine.plugins.add(WorkspaceProgramPlugin())
        MethodChannel(engine.dartExecutor.binaryMessenger, "studio.orb/overlay")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getSettings" -> result.success(settings.snapshot())
                        "consumeConversationChanged" -> {
                            val service = OrbOverlayService.current
                            if (service != null) service.consumeConversationChanged(result)
                            else result.success(settings.consumeConversationChanged())
                        }
                        "requestOverlay" -> {
                            if (settings.overlayGranted) result.success(true)
                            else if (overlayApproval != null)
                                result.error("busy", "正在等待悬浮窗授权。", null)
                            else {
                                overlayApproval = result
                                startActivityForResult(
                                    Intent(
                                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                        Uri.parse("package:$packageName"),
                                    ),
                                    OVERLAY,
                                )
                            }
                        }
                        "requestMic" -> {
                            if (settings.micGranted) result.success(true)
                            else if (micApproval != null) result.error("busy", "正在等待麦克风授权。", null)
                            else {
                                micApproval = result
                                requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC)
                            }
                        }
                        "setEnabled" -> {
                            val enabled =
                                (call.arguments as? Boolean) ?: call.argument<Boolean>("enabled")
                            require(enabled != null) { "缺少启用状态。" }
                            if (enabled) {
                                check(settings.canRun) { "请先允许悬浮窗和麦克风。" }
                                check(orbVisible) { "请在 Orb 内开启悬浮球。" }
                                startOverlay()
                                settings.enabled = true
                                if (
                                    Build.VERSION.SDK_INT >= 33 &&
                                        checkSelfPermission(
                                            Manifest.permission.POST_NOTIFICATIONS
                                        ) != PackageManager.PERMISSION_GRANTED
                                ) {
                                    requestPermissions(
                                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                        NOTIFICATIONS,
                                    )
                                }
                            } else {
                                settings.enabled = false
                                stopService(Intent(this, OrbOverlayService::class.java))
                            }
                            result.success(settings.snapshot())
                        }
                        "saveSettings" -> {
                            val hadVoice = settings.voiceEnabled
                            settings.save(
                                call.arguments as? Map<*, *>
                                    ?: throw IllegalArgumentException("设置格式错误。")
                            )
                            if (settings.enabled && hadVoice != settings.voiceEnabled)
                                startOverlay()
                            else OrbOverlayService.current?.refresh()
                            result.success(settings.snapshot())
                        }
                        else -> result.notImplemented()
                    }
                } catch (ex: Exception) {
                    if (call.method == "requestOverlay") overlayApproval = null
                    if (call.method == "requestMic") micApproval = null
                    result.error("overlay", ex.localizedMessage ?: "无法执行悬浮球操作。", null)
                }
            }
    }

    private fun startOverlay() {
        val intent = Intent(this, OrbOverlayService::class.java)
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
    }

    override fun onStart() {
        super.onStart()
        orbVisible = true
        OrbOverlayService.current?.visibilityChanged(true)
    }

    override fun onResume() {
        super.onResume()
        if (settings.enabled && OrbOverlayService.current == null) {
            if (!settings.canRun) settings.enabled = false
            else
                try {
                    startOverlay()
                } catch (_: Exception) {
                    settings.enabled = false
                }
        }
    }

    override fun onStop() {
        super.onStop()
        if (isChangingConfigurations) return
        orbVisible = false
        OrbOverlayService.current?.visibilityChanged(false)
    }

    @Deprecated("Platform activity result bridge")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == OVERLAY) {
            overlayApproval?.success(settings.overlayGranted)
            overlayApproval = null
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MIC) {
            micApproval?.success(settings.micGranted)
            micApproval = null
        }
    }

    companion object {
        internal var orbVisible = false
            private set

        private const val OVERLAY = 40761
        private const val MIC = 40762
        private const val NOTIFICATIONS = 40763
    }
}
