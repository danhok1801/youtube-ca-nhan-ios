import AVFoundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    configureBackgroundAudioSession()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance()
    )

    let win = UIWindow(frame: UIScreen.main.bounds)
    win.backgroundColor = UIColor(red: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 1)
    win.rootViewController = ViewController()
    win.makeKeyAndVisible()
    self.window = win
    return true
  }

  private func configureBackgroundAudioSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(
      .playback,
      mode: .default,
      options: [.allowAirPlay, .allowBluetoothA2DP]
    )
    try? session.setActive(true)
  }

  @objc private func handleAudioInterruption(_ note: Notification) {
    guard
      let info = note.userInfo,
      let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    if type == .ended {
      try? AVAudioSession.sharedInstance().setActive(true)
    }
  }
}
