import Flutter
import WebKit

final class WorkspaceProgramPlugin: NSObject, FlutterPlugin, WKNavigationDelegate {
  private var view: WKWebView?
  private var completion: FlutterResult?
  private var watchdog: DispatchWorkItem?
  private var activeID: Int?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "studio.orb/workspace-program", binaryMessenger: registrar.messenger())
    let plugin = WorkspaceProgramPlugin()
    registrar.addMethodCallDelegate(plugin, channel: channel)
    registrar.publish(plugin)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      result(true)
    case "run":
      guard let args = call.arguments as? [String: Any],
            let html = args["html"] as? String, let id = args["id"] as? Int else {
        result(FlutterError(code: "input", message: "缺少程序输入。", details: nil))
        return
      }
      guard view == nil else {
        result(FlutterError(code: "busy", message: "当前已有程序正在运行。", details: nil))
        return
      }
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      let job = WKWebView(frame: .zero, configuration: configuration)
      job.navigationDelegate = self
      completion = result
      view = job
      activeID = id
      let deadline = DispatchWorkItem { [weak self, weak job] in
        if let self, let job, self.view === job {
          self.fail("本地编译环境超时，已终止。")
        }
      }
      watchdog = deadline
      DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: deadline)
      job.loadHTMLString(html, baseURL: URL(string: "https://orb.invalid/"))
      poll(job)
    case "cancel":
      if let id = call.arguments as? Int, activeID == id {
        view?.evaluateJavaScript("window.orbTerminate && window.orbTerminate()", completionHandler: nil)
        fail("程序运行已停止。")
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func poll(_ job: WKWebView) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak job] in
      guard let self, let job, self.view === job else { return }
      job.evaluateJavaScript("window.orbProgramResult || null") { [weak self, weak job] value, _ in
        guard let self, let job, self.view === job else { return }
        if let response = value as? String {
          self.finish(response)
        } else {
          self.poll(job)
        }
      }
    }
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    if view === webView { fail("本地编译环境已中断。") }
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    if view != nil { fail("本地编译环境已关闭。") }
  }

  private func fail(_ message: String) {
    finish(FlutterError(code: "runtime", message: message, details: nil))
  }

  private func finish(_ value: Any) {
    watchdog?.cancel()
    watchdog = nil
    view?.navigationDelegate = nil
    view?.stopLoading()
    view = nil
    activeID = nil
    let callback = completion
    completion = nil
    callback?(value)
  }
}
