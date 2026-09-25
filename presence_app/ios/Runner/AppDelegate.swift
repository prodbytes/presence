import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Always-recording cameras (see PresenceCamerasPlugin.swift).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PresenceCamerasPlugin") {
      PresenceCamerasPlugin.register(with: registrar)
    }
  }
}
