package studio.orb.orb_mobile

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.os.*
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class OrbOverlayService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val prefs by lazy { OrbOverlaySettings(this) }
    private lateinit var window: OrbOverlayWindow
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var engineReady = false
    private var hasVoiceWork = false
    private val pending = ArrayDeque<String>()
    private var phase = "idle"
    private val screen =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == Intent.ACTION_SCREEN_OFF) {
                    dispatch("stop")
                    window.hide()
                } else refresh()
            }
        }

    override fun onCreate() {
        super.onCreate()
        current = this
        window = OrbOverlayWindow(this, prefs, ::action)
        val filter =
            IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_USER_PRESENT)
            }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(screen, filter, RECEIVER_NOT_EXPORTED)
        else registerReceiver(screen, filter)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP || !prefs.canRun) {
            prefs.enabled = false
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            val notification = notification()
            if (Build.VERSION.SDK_INT >= 29) {
                var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                if (Build.VERSION.SDK_INT >= 30 && prefs.voiceEnabled && prefs.micGranted) {
                    types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                startForeground(NOTIFICATION, notification, types)
            } else startForeground(NOTIFICATION, notification)
            refresh()
        } catch (_: RuntimeException) {
            prefs.enabled = false
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        val channelId = "orb_overlay"
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(channelId, "悬浮球", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val piFlags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val open = PendingIntent.getActivity(this, 1, appIntent(), piFlags)
        val off =
            PendingIntent.getService(
                this,
                2,
                Intent(this, OrbOverlayService::class.java).setAction(STOP),
                piFlags,
            )
        @Suppress("DEPRECATION")
        val n =
            if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channelId)
            else Notification.Builder(this)
        return n.setSmallIcon(R.drawable.orb_overlay_mark)
            .setContentTitle("Orb 悬浮球已开启")
            .setContentText("长按语音，松开发送")
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, "关闭悬浮球", off).build())
            .build()
    }

    private fun appIntent() =
        Intent(this, MainActivity::class.java)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            )

    fun refresh() {
        val keyguard = getSystemService(KeyguardManager::class.java)
        val power = getSystemService(PowerManager::class.java)
        if (!prefs.canRun) {
            prefs.enabled = false
            stopSelf()
        } else if (MainActivity.orbVisible || keyguard.isKeyguardLocked || !power.isInteractive)
            window.hide()
        else
            try {
                window.show()
                if (engine == null) {
                    window.status("starting", "", "")
                    dispatch("warm")
                }
            } catch (_: RuntimeException) {
                prefs.enabled = false
                stopSelf()
            }
    }

    fun visibilityChanged(visible: Boolean) {
        if (visible) {
            dispatch("stop")
            window.hide()
        } else refresh()
    }

    override fun onConfigurationChanged(config: android.content.res.Configuration) {
        super.onConfigurationChanged(config)
        if (!MainActivity.orbVisible) refresh()
    }

    private fun action(action: String) {
        when (action) {
            "open" -> startActivity(appIntent())
            "panel" -> if (window.togglePanel() && phase == "idle") dispatch("latest")
            "voice",
            "newVoice" -> {
                if (!prefs.voiceEnabled || !prefs.micGranted) return
                hasVoiceWork = true
                window.showPanel()
                dispatch(action)
            }
            "read" -> {
                window.showPanel()
                dispatch("read")
            }
            "stop",
            "release",
            "cancel" -> dispatch(action)
            "interruptIfSpeaking" -> if (phase == "speaking") dispatch("stop")
        }
    }

    fun consumeConversationChanged(result: MethodChannel.Result) {
        val bridge = channel
        if (!hasVoiceWork || !engineReady || bridge == null) {
            result.success(prefs.consumeConversationChanged())
            return
        }
        hasVoiceWork = false
        // The foreground engine may resume while its predecessor is committing a stopped reply.
        bridge.invokeMethod(
            "settleConversation",
            null,
            object : MethodChannel.Result {
                override fun success(value: Any?) =
                    result.success(prefs.consumeConversationChanged())

                override fun error(code: String, message: String?, details: Any?) = success(null)

                override fun notImplemented() = success(null)
            },
        )
    }

    private fun dispatch(command: String) {
        if (command == "stop" || command == "cancel") {
            if (!engineReady) pending.clear()
            if (engine == null || !engineReady) return
        }
        if (engineReady) {
            channel?.invokeMethod(command, null)
        } else {
            if (command != "warm") pending.add(command)
            if (engine == null) {
                try {
                    val loader = FlutterInjector.instance().flutterLoader()
                    loader.startInitialization(this)
                    loader.ensureInitializationComplete(this, null)
                    val worker = FlutterEngine(applicationContext)
                    worker.plugins.add(WorkspaceProgramPlugin())
                    engine = worker
                    channel =
                        MethodChannel(
                                worker.dartExecutor.binaryMessenger,
                                "studio.orb/overlay-engine",
                            )
                            .also {
                                it.setMethodCallHandler { call, result ->
                                    when (call.method) {
                                        "ready" -> {
                                            engineReady = true
                                            result.success(null)
                                            while (pending.isNotEmpty()) channel?.invokeMethod(
                                                pending.removeFirst(),
                                                null,
                                            )
                                        }
                                        "conversationChanged" -> {
                                            prefs.markConversationChanged()
                                            result.success(null)
                                        }
                                        "status" -> {
                                            phase = call.argument<String>("phase") ?: "idle"
                                            window.status(
                                                phase,
                                                call.argument<String>("answer").orEmpty(),
                                                call.argument<String>("error").orEmpty(),
                                            )
                                            result.success(null)
                                        }
                                        else -> result.notImplemented()
                                    }
                                }
                            }
                    worker.dartExecutor.executeDartEntrypoint(
                        DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "orbOverlayMain")
                    )
                } catch (_: RuntimeException) {
                    pending.clear()
                    engine?.destroy()
                    engine = null
                    channel = null
                    window.status("error", "", "无法启动语音服务，请打开 Orb 重试。")
                }
            }
        }
    }

    override fun onDestroy() {
        if (current === this) current = null
        unregisterReceiver(screen)
        window.hide()
        pending.clear()
        val worker = engine
        if (worker != null) {
            var closed = false
            val close = Runnable {
                if (!closed) {
                    closed = true
                    worker.destroy()
                }
            }
            val bridge = channel
            if (engineReady && bridge != null) {
                bridge.invokeMethod(
                    "dispose",
                    null,
                    object : MethodChannel.Result {
                        override fun success(value: Any?) {
                            main.post(close)
                        }

                        override fun error(code: String, message: String?, details: Any?) {
                            main.post(close)
                        }

                        override fun notImplemented() {
                            main.post(close)
                        }
                    },
                )
                main.postDelayed(close, 1000)
            } else main.post(close)
        }
        engine = null
        channel = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        internal var current: OrbOverlayService? = null
            private set

        private const val NOTIFICATION = 24702
        private const val STOP = "studio.orb.overlay.STOP"
    }
}
