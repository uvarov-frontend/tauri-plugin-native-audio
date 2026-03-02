import Foundation

private let postSeekBackslideClampWindowSeconds: Double = 0.03
private let playbackMonotonicClampEpsilonSeconds: Double = 0.003

struct PendingSeekContext: Sendable {
  let revision: Int64
  let sourceRevision: Int64
  let originPosition: Double
  let targetPosition: Double
  let shouldResume: Bool
}

struct PlaybackStateMachine: Sendable {
  private(set) var sourceRevision: Int64 = 0
  private(set) var seekRevision: Int64 = 0
  private(set) var playbackRate: Double = 1.0
  private(set) var desiredPlaying = false
  private(set) var lastError: String?
  private(set) var didReachEnd = false
  private(set) var currentStoryId: Int64?
  private(set) var metadata = PlaybackMetadata(title: nil, artist: nil, artworkURL: nil)
  private(set) var pendingSeek: PendingSeekContext?
  private var stickySeekTarget: Double?
  private var lastStableCurrentTime: Double = 0.0

  mutating func advanceSourceRevision() -> Int64 {
    sourceRevision += 1
    pendingSeek = nil
    stickySeekTarget = nil
    lastStableCurrentTime = 0.0
    didReachEnd = false
    desiredPlaying = false
    lastError = nil
    return sourceRevision
  }

  mutating func setStoryId(_ id: Int64?) {
    currentStoryId = (id ?? 0) > 0 ? id : nil
  }

  mutating func setMetadata(_ metadata: PlaybackMetadata) {
    self.metadata = metadata
  }

  mutating func setPlaybackRate(_ rate: Double) {
    playbackRate = rate
  }

  mutating func setDesiredPlaying(_ desired: Bool) {
    desiredPlaying = desired
  }

  mutating func markError(_ error: String?) {
    lastError = error
    if error != nil {
      pendingSeek = nil
    }
  }

  mutating func clearError() {
    lastError = nil
  }

  mutating func markEnded() {
    didReachEnd = true
    desiredPlaying = false
    pendingSeek = nil
  }

  mutating func clearEnded() {
    didReachEnd = false
  }

  mutating func clearPendingSeek() {
    pendingSeek = nil
  }

  mutating func beginSeek(position: Double, shouldResume: Bool, originPosition: Double) -> PendingSeekContext {
    seekRevision += 1
    let context = PendingSeekContext(
      revision: seekRevision,
      sourceRevision: sourceRevision,
      originPosition: max(0.0, originPosition),
      targetPosition: max(0.0, position),
      shouldResume: shouldResume
    )
    pendingSeek = context
    didReachEnd = false
    return context
  }

  mutating func resolveSeek(sourceRevision: Int64, seekRevision: Int64) -> PendingSeekContext? {
    guard let pendingSeek else {
      return nil
    }
    guard pendingSeek.sourceRevision == sourceRevision, pendingSeek.revision == seekRevision else {
      return nil
    }
    self.pendingSeek = nil
    stickySeekTarget = pendingSeek.targetPosition
    lastStableCurrentTime = pendingSeek.targetPosition
    return pendingSeek
  }

  mutating func cancelSeek(sourceRevision: Int64, seekRevision: Int64) -> Bool {
    guard let pendingSeek else {
      return false
    }
    guard pendingSeek.sourceRevision == sourceRevision, pendingSeek.revision == seekRevision else {
      return false
    }
    self.pendingSeek = nil
    return true
  }

  mutating func resetAll() {
    sourceRevision = 0
    seekRevision = 0
    playbackRate = 1.0
    desiredPlaying = false
    lastError = nil
    didReachEnd = false
    currentStoryId = nil
    pendingSeek = nil
    stickySeekTarget = nil
    lastStableCurrentTime = 0.0
    metadata = PlaybackMetadata(title: nil, artist: nil, artworkURL: nil)
  }

  mutating func makeSnapshot(
    rawCurrentTime: Double,
    rawDuration: Double,
    isActuallyPlaying: Bool,
    isBuffering: Bool
  ) -> NativeAudioState {
    let duration = (rawDuration.isFinite && rawDuration > 0) ? rawDuration : 0.0
    let baseCurrent = (rawCurrentTime.isFinite && rawCurrentTime >= 0) ? rawCurrentTime : 0.0
    let clampedCurrent = duration > 0 ? max(0.0, min(duration, baseCurrent)) : max(0.0, baseCurrent)

    let currentTime: Double
    let seekShouldResume: Bool?
    if let pendingSeek {
      currentTime = duration > 0 ? min(duration, pendingSeek.targetPosition) : pendingSeek.targetPosition
      lastStableCurrentTime = currentTime
      seekShouldResume = pendingSeek.shouldResume
    } else {
      var normalizedCurrent = clampedCurrent

      if let stickySeekTarget {
        if normalizedCurrent < stickySeekTarget {
          let delta = stickySeekTarget - normalizedCurrent
          if delta <= postSeekBackslideClampWindowSeconds {
            normalizedCurrent = stickySeekTarget
          } else {
            self.stickySeekTarget = nil
          }
        } else if normalizedCurrent - stickySeekTarget > postSeekBackslideClampWindowSeconds {
          self.stickySeekTarget = nil
        }
      }

      if isActuallyPlaying, normalizedCurrent + playbackMonotonicClampEpsilonSeconds < lastStableCurrentTime {
        normalizedCurrent = lastStableCurrentTime
      } else {
        lastStableCurrentTime = normalizedCurrent
      }

      currentTime = normalizedCurrent
      seekShouldResume = nil
    }

    let hasTerminalState = lastError != nil || didReachEnd
    let effectiveIsPlaying = hasTerminalState ? false : (seekShouldResume ?? isActuallyPlaying)
    let effectiveBuffering = hasTerminalState || seekShouldResume == false ? false : isBuffering

    let status: String
    if lastError != nil {
      status = "error"
    } else if didReachEnd {
      status = "ended"
    } else if seekShouldResume == true {
      status = "playing"
    } else if effectiveBuffering {
      status = "loading"
    } else if effectiveIsPlaying {
      status = "playing"
    } else {
      status = "idle"
    }

    return NativeAudioState(
      status: status,
      currentTime: currentTime,
      duration: duration,
      isPlaying: effectiveIsPlaying,
      buffering: effectiveBuffering,
      rate: playbackRate,
      error: lastError
    )
  }
}
