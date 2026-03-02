import Foundation
import MediaPlayer

enum RemoteCommandEvent: Sendable {
  case play
  case pause
  case toggle
  case seek(position: Double)
  case seekDelta(delta: Double)
}

final class RemoteCommandController {
  private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
  private var eventHandler: ((RemoteCommandEvent) -> Void)?

  deinit {
    unregister()
  }

  func registerIfNeeded(eventHandler: @escaping (RemoteCommandEvent) -> Void) {
    onMain {
      self.eventHandler = eventHandler
      if !remoteCommandTargets.isEmpty {
        return
      }

      let center = MPRemoteCommandCenter.shared()
      center.playCommand.isEnabled = true
      center.pauseCommand.isEnabled = true
      center.togglePlayPauseCommand.isEnabled = true
      center.changePlaybackPositionCommand.isEnabled = true
      center.skipForwardCommand.isEnabled = true
      center.skipBackwardCommand.isEnabled = true
      center.skipForwardCommand.preferredIntervals = [NSNumber(value: remoteSeekStepSeconds)]
      center.skipBackwardCommand.preferredIntervals = [NSNumber(value: remoteSeekStepSeconds)]

      let playTarget = center.playCommand.addTarget { [weak self] _ in
        self?.eventHandler?(.play)
        return .success
      }
      remoteCommandTargets.append((center.playCommand, playTarget))

      let pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
        self?.eventHandler?(.pause)
        return .success
      }
      remoteCommandTargets.append((center.pauseCommand, pauseTarget))

      let toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
        self?.eventHandler?(.toggle)
        return .success
      }
      remoteCommandTargets.append((center.togglePlayPauseCommand, toggleTarget))

      let changePositionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
        guard let seekEvent = event as? MPChangePlaybackPositionCommandEvent else {
          return .commandFailed
        }
        self?.eventHandler?(.seek(position: seekEvent.positionTime))
        return .success
      }
      remoteCommandTargets.append((center.changePlaybackPositionCommand, changePositionTarget))

      let skipForwardTarget = center.skipForwardCommand.addTarget { [weak self] _ in
        self?.eventHandler?(.seekDelta(delta: remoteSeekStepSeconds))
        return .success
      }
      remoteCommandTargets.append((center.skipForwardCommand, skipForwardTarget))

      let skipBackwardTarget = center.skipBackwardCommand.addTarget { [weak self] _ in
        self?.eventHandler?(.seekDelta(delta: -remoteSeekStepSeconds))
        return .success
      }
      remoteCommandTargets.append((center.skipBackwardCommand, skipBackwardTarget))
    }
  }

  func unregister() {
    onMain {
      let center = MPRemoteCommandCenter.shared()

      for (command, target) in remoteCommandTargets {
        command.removeTarget(target)
      }
      remoteCommandTargets.removeAll()
      eventHandler = nil

      center.playCommand.isEnabled = false
      center.pauseCommand.isEnabled = false
      center.togglePlayPauseCommand.isEnabled = false
      center.changePlaybackPositionCommand.isEnabled = false
      center.skipForwardCommand.isEnabled = false
      center.skipBackwardCommand.isEnabled = false
    }
  }

  private func onMain<T>(_ block: () -> T) -> T {
    if Thread.isMainThread {
      return block()
    }
    return DispatchQueue.main.sync(execute: block)
  }
}
