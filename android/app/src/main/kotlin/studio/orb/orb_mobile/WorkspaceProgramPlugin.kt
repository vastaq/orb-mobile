package studio.orb.orb_mobile

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import org.json.JSONTokener

class WorkspaceProgramPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    private var session: ProgramSession? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "studio.orb/workspace-program").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "available" -> result.success(
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                            WebView.getCurrentWebViewPackage() != null
                        else context.packageManager.hasSystemFeature(PackageManager.FEATURE_WEBVIEW)
                    )
                    "run" -> {
                        val html = call.argument<String>("html")
                        val id = call.argument<Number>("id")?.toLong()
                        if (html == null || id == null) result.error("input", "缺少程序输入。", null)
                        else if (session != null) result.error("busy", "当前已有程序正在运行。", null)
                        else {
                            try {
                                val job = ProgramSession(context, id) { value, error ->
                                    session = null
                                    if (error == null) result.success(value)
                                    else result.error("runtime", error, null)
                                }
                                session = job
                                job.start(html)
                            } catch (error: Exception) {
                                val job = session
                                if (job != null) job.fail("无法启动本地编译环境。")
                                else result.error("runtime", "无法启动本地编译环境。", null)
                            }
                        }
                    }
                    "cancel" -> {
                        val id = (call.arguments as? Number)?.toLong()
                        session?.takeIf { it.id == id }?.cancel()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        session?.fail("本地编译环境已关闭。")
        channel?.setMethodCallHandler(null)
        channel = null
    }
}

private class ProgramSession(
    context: Context,
    val id: Long,
    private val complete: (String?, String?) -> Unit,
) {
    private val view = WebView(context)
    private val handler = Handler(Looper.getMainLooper())
    private var finished = false

    fun start(html: String) {
        view.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            blockNetworkLoads = true
        }
        view.webViewClient = object : WebViewClient() {
            override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                fail("本地编译环境已中断。")
                return true
            }
        }
        handler.postDelayed({ fail("本地编译环境超时，已终止。") }, 30_000)
        // A synthetic HTTPS origin permits Blob workers. All input lives in this document.
        view.loadDataWithBaseURL("https://orb.invalid/", html, "text/html", "UTF-8", null)
        handler.postDelayed(::readResult, 100)
    }

    private fun readResult() {
        if (finished) return
        view.evaluateJavascript("window.orbProgramResult || null") { value ->
            if (!finished) {
                if (value == null || value == "null") handler.postDelayed(::readResult, 100)
                else {
                    val decoded = JSONTokener(value).nextValue() as? String
                    if (decoded == null) fail("无法读取程序结果。")
                    else finish(decoded, null)
                }
            }
        }
    }

    fun fail(error: String) = finish(null, error)

    fun cancel() {
        view.evaluateJavascript("window.orbTerminate && window.orbTerminate()", null)
        fail("程序运行已停止。")
    }

    private fun finish(value: String?, error: String?) {
        if (finished) return
        finished = true
        handler.removeCallbacksAndMessages(null)
        view.destroy()
        complete(value, error)
    }
}
