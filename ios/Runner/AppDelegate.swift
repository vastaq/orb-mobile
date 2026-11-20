import Flutter
import UIKit
import workmanager_apple
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in GeneratedPluginRegistrant.register(with: registry) }
    WorkmanagerPlugin.registerBGProcessingTask(withIdentifier: "studio.orb.tasks.process")
    UNUserNotificationCenter.current().delegate = self
    // SQLite includes sidecar files. Exclude the containing directory so local
    // conversations and memory also stay out of iCloud device backups.
    let manager = FileManager.default
    if let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first {
      var local = documents.appendingPathComponent("orb-local", isDirectory: true)
      do {
        try manager.createDirectory(at: local, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try local.setResourceValues(values)
      } catch {
        NSLog("Orb could not set the local database backup preference.")
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
