import Foundation

private let progressPersistThrottleSeconds: TimeInterval = 1.0
private let progressNearStartEpsilonSeconds = 0.25
private let progressPersistEpsilonSeconds = 0.05

final class CheckpointStore {
  private let defaults: UserDefaults
  private let key: String

  private var lastPersistedAt = Date.distantPast
  private var lastPersistedStoryId: Int64?
  private var lastPersistedTime: Double?

  init(defaults: UserDefaults = .standard, key: String = checkpointDefaultsKeyV1) {
    self.defaults = defaults
    self.key = key
  }

  func read() -> NativeAudioProgressCheckpoint? {
    guard let data = defaults.data(forKey: key) else {
      return nil
    }

    return try? JSONDecoder().decode(NativeAudioProgressCheckpoint.self, from: data)
  }

  func clear() {
    defaults.removeObject(forKey: key)
    lastPersistedAt = .distantPast
    lastPersistedStoryId = nil
    lastPersistedTime = nil
  }

  func persistIfNeeded(snapshot: NativeAudioState, storyId: Int64?, force: Bool, now: Date = Date()) {
    guard let storyId, storyId > 0 else {
      return
    }

    guard snapshot.currentTime.isFinite, snapshot.currentTime > progressNearStartEpsilonSeconds else {
      return
    }

    if !force, now.timeIntervalSince(lastPersistedAt) < progressPersistThrottleSeconds {
      return
    }

    if
      !force,
      lastPersistedStoryId == storyId,
      let lastPersistedTime,
      abs(lastPersistedTime - snapshot.currentTime) <= progressPersistEpsilonSeconds
    {
      return
    }

    let checkpoint = NativeAudioProgressCheckpoint(
      id: storyId,
      currentTime: snapshot.currentTime,
      updatedAtMs: Int64(now.timeIntervalSince1970 * 1000.0),
      status: snapshot.status
    )

    guard let data = try? JSONEncoder().encode(checkpoint) else {
      return
    }

    defaults.set(data, forKey: key)
    lastPersistedAt = now
    lastPersistedStoryId = storyId
    lastPersistedTime = snapshot.currentTime
  }
}
