import AVFoundation
import Foundation

private let defaultProgressInterval = CMTime(seconds: 1.0 / 40.0, preferredTimescale: 600)

enum PlayerEvent: Sendable {
  case timeControlChanged(sourceRevision: Int64)
  case itemStatusChanged(sourceRevision: Int64, status: AVPlayerItem.Status, error: String?)
  case durationChanged(sourceRevision: Int64)
  case progress(sourceRevision: Int64, currentTime: Double)
  case didReachEnd(sourceRevision: Int64)
  case failedToEnd(sourceRevision: Int64, error: String?)
  case seekCompleted(sourceRevision: Int64, seekRevision: Int64, finished: Bool, currentTime: Double)
}

final class PlayerAdapter {
  private var player: AVPlayer?
  private var timeControlStatusObservation: NSKeyValueObservation?
  private var itemStatusObservation: NSKeyValueObservation?
  private var itemDurationObservation: NSKeyValueObservation?
  private var periodicTimeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var failedToEndObserver: NSObjectProtocol?

  private var currentSourceRevision: Int64 = 0
  private var eventHandler: ((PlayerEvent) -> Void)?

  init(eventHandler: ((PlayerEvent) -> Void)? = nil) {
    self.eventHandler = eventHandler
  }

  deinit {
    dispose()
  }

  func setEventHandler(_ handler: ((PlayerEvent) -> Void)?) {
    onMain {
      eventHandler = handler
    }
  }

  func ensurePlayer() {
    onMain {
      if player != nil {
        return
      }

      let nextPlayer = AVPlayer()
      nextPlayer.automaticallyWaitsToMinimizeStalling = true
      player = nextPlayer

      timeControlStatusObservation = nextPlayer.observe(
        \.timeControlStatus,
        options: [.initial, .new]
      ) { [weak self] _, _ in
        guard let self else { return }
        self.eventHandler?(.timeControlChanged(sourceRevision: self.currentSourceRevision))
      }

      periodicTimeObserver = nextPlayer.addPeriodicTimeObserver(
        forInterval: defaultProgressInterval,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.eventHandler?(.progress(sourceRevision: self.currentSourceRevision, currentTime: self.currentTimeSeconds()))
      }

      observeCurrentItem(sourceRevision: currentSourceRevision)
    }
  }

  func replaceCurrentItem(url: URL, sourceRevision: Int64) {
    onMain {
      ensurePlayer()
      currentSourceRevision = sourceRevision
      clearCurrentItemObservers()
      let nextItem = AVPlayerItem(url: url)
      player?.replaceCurrentItem(with: nextItem)
      observeCurrentItem(sourceRevision: sourceRevision)
    }
  }

  func play(rate: Double) {
    onMain {
      ensurePlayer()
      player?.play()
      if rate != 1.0 {
        player?.rate = Float(rate)
      }
    }
  }

  func pause() {
    onMain {
      player?.pause()
    }
  }

  func setRate(_ rate: Double) {
    onMain {
      guard rate.isFinite, rate > 0 else {
        return
      }
      if isActuallyPlaying() {
        player?.rate = Float(rate)
      }
    }
  }

  func seek(to position: Double, sourceRevision: Int64, seekRevision: Int64) {
    onMain {
      guard let player else {
        eventHandler?(.seekCompleted(sourceRevision: sourceRevision, seekRevision: seekRevision, finished: false, currentTime: 0.0))
        return
      }

      let target = CMTime(seconds: max(0.0, position), preferredTimescale: 600)
      player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
        guard let self else { return }
        self.onMain {
          self.eventHandler?(
            .seekCompleted(
              sourceRevision: sourceRevision,
              seekRevision: seekRevision,
              finished: finished,
              currentTime: self.currentTimeSeconds()
            )
          )
        }
      }
    }
  }

  func isActuallyPlaying() -> Bool {
    onMain {
      player?.timeControlStatus == .playing
    }
  }

  func isBuffering() -> Bool {
    onMain {
      player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }
  }

  func currentTimeSeconds() -> Double {
    onMain {
      guard let player else {
        return 0.0
      }
      let value = player.currentTime().seconds
      guard value.isFinite else {
        return 0.0
      }
      return max(0.0, value)
    }
  }

  func durationSeconds() -> Double {
    onMain {
      guard let duration = player?.currentItem?.duration.seconds else {
        return 0.0
      }
      guard duration.isFinite, duration > 0 else {
        return 0.0
      }
      return duration
    }
  }

  func dispose() {
    onMain {
      clearCurrentItemObservers()
      timeControlStatusObservation = nil

      if let periodicTimeObserver, let player {
        player.removeTimeObserver(periodicTimeObserver)
        self.periodicTimeObserver = nil
      }

      player?.pause()
      player?.replaceCurrentItem(with: nil)
      player = nil
    }
  }

  private func observeCurrentItem(sourceRevision: Int64) {
    clearCurrentItemObservers()
    guard let item = player?.currentItem else {
      return
    }

    itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      guard let self else { return }
      self.eventHandler?(.itemStatusChanged(sourceRevision: sourceRevision, status: item.status, error: item.error?.localizedDescription))
    }

    itemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] _, _ in
      guard let self else { return }
      self.eventHandler?(.durationChanged(sourceRevision: sourceRevision))
    }

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      self?.eventHandler?(.didReachEnd(sourceRevision: sourceRevision))
    }

    failedToEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] notification in
      let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
      self?.eventHandler?(.failedToEnd(sourceRevision: sourceRevision, error: error?.localizedDescription))
    }
  }

  private func clearCurrentItemObservers() {
    itemStatusObservation = nil
    itemDurationObservation = nil

    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }

    if let failedToEndObserver {
      NotificationCenter.default.removeObserver(failedToEndObserver)
      self.failedToEndObserver = nil
    }
  }

  private func onMain<T>(_ block: () -> T) -> T {
    if Thread.isMainThread {
      return block()
    }
    return DispatchQueue.main.sync(execute: block)
  }
}
