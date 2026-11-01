import UIKit
import Flutter
import AVFAudio

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    configureAudioSessionForFreeFire(preserveStereo: true)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let audioChannel = FlutterMethodChannel(
      name: "com.squadvoice.ff/audio_session",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )

    audioChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      if call.method == "configureGameAudioSession" {
        let args = call.arguments as? [String: Any]
        let preserveStereo = args?["preserveGameStereo"] as? Bool ?? true
        self?.configureAudioSessionForFreeFire(preserveStereo: preserveStereo)
        result(true)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Configures iOS 16 AVAudioSession on iPhone 8 Plus so Free Fire keeps full stereo volume
  /// without iOS ducking (lowering) footstep and gunshot audio while SquadVoice runs in the background.
  private func configureAudioSessionForFreeFire(preserveStereo: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
      var options: AVAudioSession.CategoryOptions = [
        .mixWithOthers,
        .defaultToSpeaker,
        .allowBluetooth
      ]
      if preserveStereo {
        options.insert(.allowBluetoothA2DP)
      }
      try session.setCategory(
        .playAndRecord,
        mode: preserveStereo ? .default : .voiceChat,
        options: options
      )
      try session.setActive(true)
    } catch {
      print("AVAudioSession configuration error: \(error)")
    }
  }
}