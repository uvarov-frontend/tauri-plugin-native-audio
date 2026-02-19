import AVFoundation
import Foundation
import MediaPlayer
import Tauri
import UIKit

private let eventState = "native_audio_state"
private let remoteSeekStepSeconds = 10.0
private let progressInterval = CMTime(seconds: 1.0 / 20.0, preferredTimescale: 600)
private let preparedSourcesDirectoryName = "tauri-plugin-native-audio"
private let preparedSourceStaleThresholdSeconds: TimeInterval = 24 * 60 * 60

private struct NativeAudioState: Encodable {
  let status: String
  let currentTime: Double
  let duration: Double
  let isPlaying: Bool
  let buffering: Bool
  let rate: Double
  let error: String?
}

private struct SetSourceArgs: Decodable {
  let src: String
  let title: String?
  let artist: String?
  let artworkUrl: String?
}

private struct SeekToArgs: Decodable {
  let position: Double?
}

private struct SetRateArgs: Decodable {
  let rate: Double?
}

private enum NativeAudioRuntimeError: LocalizedError {
  case invalidSource
  case invalidRate

  var errorDescription: String? {
    switch self {
    case .invalidSource:
      return "invalid source"
    case .invalidRate:
      return "rate must be > 0"
    }
  }
}

private final class NativeAudioRuntime: NSObject {
  static let shared = NativeAudioRuntime()

  weak var plugin: NativeAudioPlugin?

  private var player: AVPlayer?
  private var timeControlStatusObservation: NSKeyValueObservation?
  private var itemStatusObservation: NSKeyValueObservation?
  private var itemDurationObservation: NSKeyValueObservation?
  private var periodicTimeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var failedToEndObserver: NSObjectProtocol?
  private var audioSessionInterruptionObserver: NSObjectProtocol?
  private var audioSessionRouteChangeObserver: NSObjectProtocol?
  private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
  private var preparedLocalSourceURL: URL?

  private var lastError: String?
  private var playbackRate = 1.0
  private var didReachEnd = false
  private var wasPlayingBeforeInterruption = false

  private var nowPlayingTitle: String?
  private var nowPlayingArtist: String?
  private var nowPlayingArtworkURL: String?
  private var nowPlayingArtwork: MPMediaItemArtwork?
  private var loadedArtworkURL: String?
  private var artworkTaskId = UUID()

  private override init() {
    super.init()
  }

  func attach(plugin: NativeAudioPlugin) {
    self.plugin = plugin
  }

  func detach(plugin: NativeAudioPlugin) {
    if self.plugin === plugin {
      self.plugin = nil
    }
  }

  func initialize() throws -> NativeAudioState {
    try onMain {
      ensurePlayer()
      try configureAudioSessionCategory()
      registerRemoteCommandsIfNeeded()
      cleanupPreparedSourceDirectory()
      updateNowPlayingInfo()
      emitState()
      return snapshotLocked()
    }
  }

  func setSource(src: String, title: String?, artist: String?, artworkURL: String?) throws -> NativeAudioState {
    try onMain {
      ensurePlayer()
      try configureAudioSessionCategory()

      guard let normalizedURL = normalizeSourceURL(src) else {
        throw NativeAudioRuntimeError.invalidSource
      }
      let playbackURL = preparePlayableURL(normalizedURL)

      cleanupPreparedLocalSource()
      preparedLocalSourceURL = playbackURL.isFileURL && playbackURL != normalizedURL ? playbackURL : nil

      let nextItem = AVPlayerItem(url: playbackURL)
      player?.pause()
      clearCurrentItemObservers()
      player?.replaceCurrentItem(with: nextItem)
      observeCurrentItem()

      lastError = nil
      didReachEnd = false

      nowPlayingTitle = title
      nowPlayingArtist = artist
      nowPlayingArtworkURL = artworkURL
      updateNowPlayingInfo(refreshArtwork: true)
      emitState()
      return snapshotLocked()
    }
  }

  func play() throws -> NativeAudioState {
    try onMain {
      ensurePlayer()
      try configureAudioSessionCategory()
      try setAudioSessionActive(true)
      registerRemoteCommandsIfNeeded()

      if didReachEnd {
        didReachEnd = false
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
      }

      player?.play()
      if playbackRate != 1.0 {
        player?.rate = Float(playbackRate)
      }
      lastError = nil
      updateNowPlayingInfo()
      emitState()
      return snapshotLocked()
    }
  }

  func pause() -> NativeAudioState {
    onMain {
      player?.pause()
      updateNowPlayingInfo()
      emitState()
      return snapshotLocked()
    }
  }

  func seekTo(position: Double) -> NativeAudioState {
    onMain {
      guard let player else {
        return snapshotLocked()
      }

      let safePosition = max(0, position)
      let shouldResume = isActuallyPlayingLocked()
      didReachEnd = false

      let target = CMTime(seconds: safePosition, preferredTimescale: 600)
      player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
        guard finished, let self else { return }
        DispatchQueue.main.async {
          if shouldResume {
            self.player?.play()
            if self.playbackRate != 1.0 {
              self.player?.rate = Float(self.playbackRate)
            }
          }
          self.updateNowPlayingInfo()
          self.emitState()
        }
      }

      updateNowPlayingInfo()
      emitState()
      return snapshotLocked()
    }
  }

  func setRate(rate: Double) throws -> NativeAudioState {
    try onMain {
      guard rate.isFinite, rate > 0 else {
        throw NativeAudioRuntimeError.invalidRate
      }

      playbackRate = rate
      if isActuallyPlayingLocked() {
        player?.rate = Float(rate)
      }
      updateNowPlayingInfo()
      emitState()
      return snapshotLocked()
    }
  }

  func getState() -> NativeAudioState {
    onMain {
      snapshotLocked()
    }
  }

  func dispose() {
    onMain {
      unregisterRemoteCommands()
      clearNowPlayingInfo()
      removePlayerObservers()
      cleanupPreparedLocalSource()
      cleanupPreparedSourceDirectory(removeAll: true)

      player?.pause()
      player?.replaceCurrentItem(with: nil)
      player = nil

      lastError = nil
      didReachEnd = false
      playbackRate = 1.0
      nowPlayingTitle = nil
      nowPlayingArtist = nil
      nowPlayingArtworkURL = nil
      nowPlayingArtwork = nil
      loadedArtworkURL = nil
      artworkTaskId = UUID()
      wasPlayingBeforeInterruption = false

      try? setAudioSessionActive(false)
      emitState()
    }
  }

  private func onMain<T>(_ block: () throws -> T) rethrows -> T {
    if Thread.isMainThread {
      return try block()
    }
    return try DispatchQueue.main.sync(execute: block)
  }

  private func ensurePlayer() {
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
      self?.handlePlaybackStateChanged()
    }

    periodicTimeObserver = nextPlayer.addPeriodicTimeObserver(
      forInterval: progressInterval,
      queue: .main
    ) { [weak self] _ in
      self?.handleProgressTick()
    }

    registerAudioSessionObserversIfNeeded()
    observeCurrentItem()
  }

  private func observeCurrentItem() {
    clearCurrentItemObservers()
    guard let item = player?.currentItem else {
      return
    }

    itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      self?.handleItemStatusChanged(item)
    }

    itemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] _, _ in
      self?.updateNowPlayingInfo()
      self?.emitState()
    }

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      self?.didReachEnd = true
      self?.updateNowPlayingInfo()
      self?.emitState()
    }

    failedToEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] notification in
      let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
      self?.lastError = error?.localizedDescription ?? "failed to play audio"
      self?.updateNowPlayingInfo()
      self?.emitState()
    }
  }

  private func clearCurrentItemObservers() {
    itemStatusObservation = nil
    itemDurationObservation = nil
    if let observer = endObserver {
      NotificationCenter.default.removeObserver(observer)
      endObserver = nil
    }
    if let observer = failedToEndObserver {
      NotificationCenter.default.removeObserver(observer)
      failedToEndObserver = nil
    }
  }

  private func removePlayerObservers() {
    clearCurrentItemObservers()
    timeControlStatusObservation = nil

    if let periodicTimeObserver, let player {
      player.removeTimeObserver(periodicTimeObserver)
      self.periodicTimeObserver = nil
    }

    unregisterAudioSessionObservers()
  }

  private func cleanupPreparedLocalSource() {
    guard let preparedLocalSourceURL else { return }
    try? FileManager.default.removeItem(at: preparedLocalSourceURL)
    self.preparedLocalSourceURL = nil
  }

  private func preparedSourcesDirectoryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(preparedSourcesDirectoryName, isDirectory: true)
  }

  private func cleanupPreparedSourceDirectory(removeAll: Bool = false) {
    let dir = preparedSourcesDirectoryURL()
    guard let fileURLs = try? FileManager.default.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      return
    }

    let now = Date()
    for fileURL in fileURLs {
      if !removeAll, let current = preparedLocalSourceURL, current == fileURL {
        continue
      }

      if removeAll {
        try? FileManager.default.removeItem(at: fileURL)
        continue
      }

      let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
      let modifiedAt = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
      if now.timeIntervalSince(modifiedAt) >= preparedSourceStaleThresholdSeconds {
        try? FileManager.default.removeItem(at: fileURL)
      }
    }
  }

  private func preparePlayableURL(_ url: URL) -> URL {
    guard url.isFileURL else {
      return url
    }

    let ext = url.pathExtension.lowercased()
    if ext != "bin" && !ext.isEmpty {
      return url
    }

    guard let detectedExtension = detectAudioExtension(for: url) else {
      return url
    }

    let cacheDir = preparedSourcesDirectoryURL()
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

    let fileName = "source-\(UUID().uuidString).\(detectedExtension)"
    let aliasURL = cacheDir.appendingPathComponent(fileName, isDirectory: false)

    do {
      try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: url)
    } catch {
      do {
        try FileManager.default.copyItem(at: url, to: aliasURL)
      } catch {
        return url
      }
    }

    return aliasURL
  }

  private func detectAudioExtension(for fileURL: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
      return nil
    }
    defer {
      handle.closeFile()
    }

    let header = handle.readData(ofLength: 16)
    guard !header.isEmpty else {
      return nil
    }

    let bytes = [UInt8](header)
    if bytes.count >= 3 && bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 {
      return "mp3"
    }
    if bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 {
      return "mp3"
    }
    if bytes.count >= 12
      && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46
      && bytes[8] == 0x57 && bytes[9] == 0x41 && bytes[10] == 0x56 && bytes[11] == 0x45
    {
      return "wav"
    }
    if bytes.count >= 12
      && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70
    {
      return "m4a"
    }
    if bytes.count >= 4 && bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53 {
      return "ogg"
    }

    return nil
  }

  private func handleItemStatusChanged(_ item: AVPlayerItem) {
    switch item.status {
    case .readyToPlay:
      if lastError != nil {
        lastError = nil
      }
    case .failed:
      lastError = item.error?.localizedDescription ?? "failed to load audio source"
    case .unknown:
      break
    @unknown default:
      break
    }

    updateNowPlayingInfo()
    emitState()
  }

  private func handlePlaybackStateChanged() {
    if isActuallyPlayingLocked(), didReachEnd {
      didReachEnd = false
    }
    updateNowPlayingInfo()
    emitState()
  }

  private func handleProgressTick() {
    guard isActuallyPlayingLocked() else {
      return
    }
    emitState()
  }

  private func isActuallyPlayingLocked() -> Bool {
    player?.timeControlStatus == .playing
  }

  private func configureAudioSessionCategory() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, options: [])
  }

  private func setAudioSessionActive(_ active: Bool) throws {
    let session = AVAudioSession.sharedInstance()
    if active {
      try session.setActive(true)
      return
    }
    try session.setActive(false, options: [.notifyOthersOnDeactivation])
  }

  private func registerAudioSessionObserversIfNeeded() {
    let center = NotificationCenter.default

    if audioSessionInterruptionObserver == nil {
      audioSessionInterruptionObserver = center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        queue: .main
      ) { [weak self] notification in
        self?.handleAudioSessionInterruption(notification)
      }
    }

    if audioSessionRouteChangeObserver == nil {
      audioSessionRouteChangeObserver = center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: AVAudioSession.sharedInstance(),
        queue: .main
      ) { [weak self] notification in
        self?.handleAudioSessionRouteChange(notification)
      }
    }
  }

  private func unregisterAudioSessionObservers() {
    let center = NotificationCenter.default

    if let observer = audioSessionInterruptionObserver {
      center.removeObserver(observer)
      audioSessionInterruptionObserver = nil
    }
    if let observer = audioSessionRouteChangeObserver {
      center.removeObserver(observer)
      audioSessionRouteChangeObserver = nil
    }
  }

  private func handleAudioSessionInterruption(_ notification: Notification) {
    guard
      let userInfo = notification.userInfo,
      let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: rawType)
    else {
      return
    }

    switch type {
    case .began:
      wasPlayingBeforeInterruption = isActuallyPlayingLocked()
      if wasPlayingBeforeInterruption {
        player?.pause()
      }
      updateNowPlayingInfo()
      emitState()
    case .ended:
      defer { wasPlayingBeforeInterruption = false }
      guard wasPlayingBeforeInterruption else {
        updateNowPlayingInfo()
        emitState()
        return
      }

      let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
      guard options.contains(.shouldResume) else {
        updateNowPlayingInfo()
        emitState()
        return
      }

      do {
        _ = try play()
      } catch {
        lastError = error.localizedDescription
        updateNowPlayingInfo()
        emitState()
      }
    @unknown default:
      updateNowPlayingInfo()
      emitState()
    }
  }

  private func handleAudioSessionRouteChange(_ notification: Notification) {
    guard
      let userInfo = notification.userInfo,
      let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
    else {
      return
    }

    if reason == .oldDeviceUnavailable, isActuallyPlayingLocked() {
      player?.pause()
    }

    updateNowPlayingInfo()
    emitState()
  }

  private func registerRemoteCommandsIfNeeded() {
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
      guard let self else { return .commandFailed }
      do {
        _ = try self.play()
      } catch {
        return .commandFailed
      }
      return .success
    }
    remoteCommandTargets.append((center.playCommand, playTarget))

    let pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      _ = self.pause()
      return .success
    }
    remoteCommandTargets.append((center.pauseCommand, pauseTarget))

    let toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      if self.isActuallyPlayingLocked() {
        _ = self.pause()
      } else {
        do {
          _ = try self.play()
        } catch {
          return .commandFailed
        }
      }
      return .success
    }
    remoteCommandTargets.append((center.togglePlayPauseCommand, toggleTarget))

    let changePositionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard
        let self,
        let seekEvent = event as? MPChangePlaybackPositionCommandEvent
      else { return .commandFailed }
      _ = self.seekTo(position: seekEvent.positionTime)
      return .success
    }
    remoteCommandTargets.append((center.changePlaybackPositionCommand, changePositionTarget))

    let skipForwardTarget = center.skipForwardCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      let next = self.getState().currentTime + remoteSeekStepSeconds
      _ = self.seekTo(position: next)
      return .success
    }
    remoteCommandTargets.append((center.skipForwardCommand, skipForwardTarget))

    let skipBackwardTarget = center.skipBackwardCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      let next = self.getState().currentTime - remoteSeekStepSeconds
      _ = self.seekTo(position: next)
      return .success
    }
    remoteCommandTargets.append((center.skipBackwardCommand, skipBackwardTarget))
  }

  private func unregisterRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()

    for (command, target) in remoteCommandTargets {
      command.removeTarget(target)
    }
    remoteCommandTargets.removeAll()

    center.playCommand.isEnabled = false
    center.pauseCommand.isEnabled = false
    center.togglePlayPauseCommand.isEnabled = false
    center.changePlaybackPositionCommand.isEnabled = false
    center.skipForwardCommand.isEnabled = false
    center.skipBackwardCommand.isEnabled = false
  }

  private func currentTimeSeconds() -> Double {
    guard let player else { return 0.0 }
    let value = player.currentTime().seconds
    guard value.isFinite else { return 0.0 }
    return max(0.0, value)
  }

  private func durationSeconds() -> Double {
    guard let duration = player?.currentItem?.duration.seconds else { return 0.0 }
    guard duration.isFinite, duration > 0 else { return 0.0 }
    return duration
  }

  private func snapshotLocked() -> NativeAudioState {
    guard let player else {
      return NativeAudioState(
        status: "idle",
        currentTime: 0.0,
        duration: 0.0,
        isPlaying: false,
        buffering: false,
        rate: playbackRate,
        error: nil
      )
    }

    let duration = durationSeconds()
    let rawCurrentTime = currentTimeSeconds()
    let currentTime = duration > 0 ? max(0.0, min(duration, rawCurrentTime)) : rawCurrentTime
    let buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    let isPlaying = isActuallyPlayingLocked()

    let status: String
    if lastError != nil {
      status = "error"
    } else if didReachEnd {
      status = "ended"
    } else if buffering {
      status = "loading"
    } else if isPlaying {
      status = "playing"
    } else {
      status = "idle"
    }

    return NativeAudioState(
      status: status,
      currentTime: currentTime,
      duration: duration,
      isPlaying: isPlaying,
      buffering: buffering,
      rate: playbackRate,
      error: lastError
    )
  }

  private func emitState() {
    guard let plugin else { return }
    try? plugin.trigger(eventState, data: snapshotLocked())
  }

  private func updateNowPlayingInfo(refreshArtwork: Bool = false) {
    guard player != nil else {
      return
    }

    if refreshArtwork {
      fetchArtworkIfNeeded()
    }

    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

    if let title = nowPlayingTitle, !title.isEmpty {
      info[MPMediaItemPropertyTitle] = title
    } else {
      info.removeValue(forKey: MPMediaItemPropertyTitle)
    }

    if let artist = nowPlayingArtist, !artist.isEmpty {
      info[MPMediaItemPropertyArtist] = artist
    } else {
      info.removeValue(forKey: MPMediaItemPropertyArtist)
    }

    let duration = durationSeconds()
    if duration > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = duration
    } else {
      info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
    }

    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTimeSeconds()
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = playbackRate
    info[MPNowPlayingInfoPropertyPlaybackRate] = isActuallyPlayingLocked() ? playbackRate : 0.0

    if let artwork = nowPlayingArtwork {
      info[MPMediaItemPropertyArtwork] = artwork
    } else {
      info.removeValue(forKey: MPMediaItemPropertyArtwork)
    }

    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func clearNowPlayingInfo() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  private func fetchArtworkIfNeeded() {
    guard
      let rawURL = nowPlayingArtworkURL?.trimmingCharacters(in: .whitespacesAndNewlines),
      !rawURL.isEmpty
    else {
      nowPlayingArtwork = nil
      loadedArtworkURL = nil
      updateNowPlayingInfo()
      return
    }

    if rawURL == loadedArtworkURL, nowPlayingArtwork != nil {
      return
    }

    guard let url = URL(string: rawURL) else {
      nowPlayingArtwork = nil
      loadedArtworkURL = nil
      updateNowPlayingInfo()
      return
    }

    nowPlayingArtwork = nil
    loadedArtworkURL = nil
    let taskId = UUID()
    artworkTaskId = taskId

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      guard let image = self.loadArtworkImage(from: url) else { return }
      DispatchQueue.main.async {
        guard self.artworkTaskId == taskId else { return }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        self.nowPlayingArtwork = artwork
        self.loadedArtworkURL = rawURL
        self.updateNowPlayingInfo()
      }
    }
  }

  private func loadArtworkImage(from url: URL) -> UIImage? {
    let data: Data?
    if url.isFileURL {
      data = try? Data(contentsOf: url)
    } else {
      data = try? Data(contentsOf: url, options: [.mappedIfSafe])
    }
    guard let data else { return nil }
    return UIImage(data: data)
  }

  private func decodeLocalPath(_ encodedPath: String) -> String {
    var path = encodedPath.removingPercentEncoding ?? encodedPath
    while path.hasPrefix("//") {
      path.removeFirst()
    }
    if !path.hasPrefix("/") {
      path = "/" + path
    }
    return path
  }

  private func normalizeSourceURL(_ src: String) -> URL? {
    let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return nil
    }

    if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
      switch scheme {
      case "https":
        return url
      case "http":
        if url.host?.lowercased() == "asset.localhost" {
          let path = decodeLocalPath(url.path)
          return URL(fileURLWithPath: path)
        }
        return url
      case "file":
        return url
      case "asset":
        if url.host?.lowercased() == "localhost" {
          let path = decodeLocalPath(url.path)
          return URL(fileURLWithPath: path)
        }
        return url
      default:
        break
      }
    }

    if let decoded = trimmed.removingPercentEncoding, decoded.hasPrefix("/") {
      return URL(fileURLWithPath: decoded)
    }

    return URL(fileURLWithPath: trimmed)
  }
}

class NativeAudioPlugin: Plugin {
  private let runtime = NativeAudioRuntime.shared

  private func runOnMain(_ invoke: Invoke, _ task: @escaping () throws -> Void) {
    let execute = {
      do {
        try task()
      } catch {
        invoke.reject(error.localizedDescription)
      }
    }

    if Thread.isMainThread {
      execute()
    } else {
      DispatchQueue.main.async(execute: execute)
    }
  }

  override init() {
    super.init()
    runtime.attach(plugin: self)
  }

  deinit {
    runtime.detach(plugin: self)
  }

  @objc public func initialize(_ invoke: Invoke) {
    runOnMain(invoke) {
      invoke.resolve(try self.runtime.initialize())
    }
  }

  @objc public func setSource(_ invoke: Invoke) {
    runOnMain(invoke) {
      let args = try invoke.parseArgs(SetSourceArgs.self)
      let src = args.src.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !src.isEmpty else {
        invoke.reject("src is required")
        return
      }

      invoke.resolve(
        try self.runtime.setSource(
          src: src,
          title: args.title,
          artist: args.artist,
          artworkURL: args.artworkUrl
        )
      )
    }
  }

  @objc public func play(_ invoke: Invoke) {
    runOnMain(invoke) {
      invoke.resolve(try self.runtime.play())
    }
  }

  @objc public func pause(_ invoke: Invoke) {
    runOnMain(invoke) {
      invoke.resolve(self.runtime.pause())
    }
  }

  @objc public func seekTo(_ invoke: Invoke) {
    runOnMain(invoke) {
      let args = try invoke.parseArgs(SeekToArgs.self)
      guard let position = args.position, position.isFinite else {
        invoke.reject("position is required")
        return
      }
      invoke.resolve(self.runtime.seekTo(position: position))
    }
  }

  @objc public func setRate(_ invoke: Invoke) {
    runOnMain(invoke) {
      let args = try invoke.parseArgs(SetRateArgs.self)
      guard let rate = args.rate, rate.isFinite, rate > 0 else {
        invoke.reject("rate must be > 0")
        return
      }
      invoke.resolve(try self.runtime.setRate(rate: rate))
    }
  }

  @objc public func getState(_ invoke: Invoke) {
    runOnMain(invoke) {
      invoke.resolve(self.runtime.getState())
    }
  }

  @objc public func dispose(_ invoke: Invoke) {
    runOnMain(invoke) {
      self.runtime.dispose()
      invoke.resolve()
    }
  }
}

@_cdecl("init_plugin_native_audio")
func initPlugin() -> Plugin {
  return NativeAudioPlugin()
}
