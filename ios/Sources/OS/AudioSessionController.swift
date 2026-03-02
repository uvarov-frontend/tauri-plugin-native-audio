import AVFoundation
import Foundation
import UIKit

enum AudioSessionEvent: Sendable {
  case interruptionBegan
  case interruptionEnded(shouldResume: Bool)
  case oldDeviceUnavailable
}

final class AudioSessionController {
  private var interruptionObserver: NSObjectProtocol?
  private var routeChangeObserver: NSObjectProtocol?
  private var eventHandler: ((AudioSessionEvent) -> Void)?

  deinit {
    unregisterObservers()
  }

  func configurePlaybackCategory() throws {
    try onMain {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [])
    }
  }

  func setActive(_ active: Bool) throws {
    try onMain {
      let session = AVAudioSession.sharedInstance()
      if active {
        try session.setActive(true)
        UIApplication.shared.beginReceivingRemoteControlEvents()
      } else {
        UIApplication.shared.endReceivingRemoteControlEvents()
        try session.setActive(false, options: [.notifyOthersOnDeactivation])
      }
    }
  }

  func registerObserversIfNeeded(eventHandler: @escaping (AudioSessionEvent) -> Void) {
    onMain {
      self.eventHandler = eventHandler
      let center = NotificationCenter.default

      if interruptionObserver == nil {
        interruptionObserver = center.addObserver(
          forName: AVAudioSession.interruptionNotification,
          object: AVAudioSession.sharedInstance(),
          queue: .main
        ) { [weak self] notification in
          self?.handleInterruption(notification)
        }
      }

      if routeChangeObserver == nil {
        routeChangeObserver = center.addObserver(
          forName: AVAudioSession.routeChangeNotification,
          object: AVAudioSession.sharedInstance(),
          queue: .main
        ) { [weak self] notification in
          self?.handleRouteChange(notification)
        }
      }
    }
  }

  func unregisterObservers() {
    onMain {
      let center = NotificationCenter.default

      if let interruptionObserver {
        center.removeObserver(interruptionObserver)
        self.interruptionObserver = nil
      }

      if let routeChangeObserver {
        center.removeObserver(routeChangeObserver)
        self.routeChangeObserver = nil
      }

      eventHandler = nil
    }
  }

  private func handleInterruption(_ notification: Notification) {
    guard
      let userInfo = notification.userInfo,
      let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: rawType)
    else {
      return
    }

    switch type {
    case .began:
      eventHandler?(.interruptionBegan)
    case .ended:
      let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
      eventHandler?(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
    @unknown default:
      break
    }
  }

  private func handleRouteChange(_ notification: Notification) {
    guard
      let userInfo = notification.userInfo,
      let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
    else {
      return
    }

    if reason == .oldDeviceUnavailable {
      eventHandler?(.oldDeviceUnavailable)
    }
  }

  private func onMain<T>(_ block: () throws -> T) rethrows -> T {
    if Thread.isMainThread {
      return try block()
    }
    return try DispatchQueue.main.sync(execute: block)
  }
}
