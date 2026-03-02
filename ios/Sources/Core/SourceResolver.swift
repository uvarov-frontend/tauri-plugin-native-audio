import CryptoKit
import Foundation

private let preparedSourcesDirectoryName = "tauri-plugin-native-audio"
private let preparedSourceStaleThresholdSeconds: TimeInterval = 24 * 60 * 60

actor SourceResolver {
  private let fileManager = FileManager.default
  private var activeAliasURL: URL?

  func resolvePlayableURL(src: String) throws -> URL {
    guard let normalized = normalizeSourceURL(src) else {
      throw NativeAudioRuntimeError.invalidSource
    }

    let playbackURL = preparePlayableURL(normalized)
    if playbackURL.isFileURL, playbackURL.deletingLastPathComponent() == preparedSourcesDirectoryURL() {
      activeAliasURL = playbackURL
    } else {
      activeAliasURL = nil
    }

    cleanupPreparedSourceDirectory(removeAll: false)
    return playbackURL
  }

  func cleanupAll() {
    activeAliasURL = nil
    cleanupPreparedSourceDirectory(removeAll: true)
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
    do {
      try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    } catch {
      return url
    }

    let aliasName = stableAliasFileName(for: url, extension: detectedExtension)
    let aliasURL = cacheDir.appendingPathComponent(aliasName, isDirectory: false)

    if fileManager.fileExists(atPath: aliasURL.path) {
      return aliasURL
    }

    do {
      try fileManager.linkItem(at: url, to: aliasURL)
      return aliasURL
    } catch {
      do {
        try fileManager.copyItem(at: url, to: aliasURL)
        return aliasURL
      } catch {
        return url
      }
    }
  }

  private func stableAliasFileName(for sourceURL: URL, extension ext: String) -> String {
    let attrs = (try? fileManager.attributesOfItem(atPath: sourceURL.path)) ?? [:]
    let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
    let fingerprint = "\(sourceURL.path)|\(size)|\(mtime)|\(ext)"
    let digest = SHA256.hash(data: Data(fingerprint.utf8))
    let hash = digest.map { String(format: "%02x", $0) }.joined()
    return "source-\(hash).\(ext)"
  }

  private func preparedSourcesDirectoryURL() -> URL {
    fileManager.temporaryDirectory.appendingPathComponent(preparedSourcesDirectoryName, isDirectory: true)
  }

  private func cleanupPreparedSourceDirectory(removeAll: Bool) {
    let dir = preparedSourcesDirectoryURL()

    guard let fileURLs = try? fileManager.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      return
    }

    let now = Date()
    for fileURL in fileURLs {
      if !removeAll, let activeAliasURL, fileURL == activeAliasURL {
        continue
      }

      if removeAll {
        try? fileManager.removeItem(at: fileURL)
        continue
      }

      let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
      let modifiedAt = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
      if now.timeIntervalSince(modifiedAt) >= preparedSourceStaleThresholdSeconds {
        try? fileManager.removeItem(at: fileURL)
      }
    }
  }

  private func detectAudioExtension(for fileURL: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
      return nil
    }
    defer {
      try? handle.close()
    }

    let header: Data
    if #available(iOS 13.4, *) {
      header = (try? handle.read(upToCount: 16)) ?? Data()
    } else {
      header = handle.readData(ofLength: 16)
    }
    guard !header.isEmpty else {
      return nil
    }

    let bytes = [UInt8](header)
    if bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
      return "mp3"
    }
    if bytes.count >= 2, bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 {
      return "mp3"
    }
    if bytes.count >= 12,
      bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
      bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45
    {
      return "wav"
    }
    if bytes.count >= 12,
      bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70
    {
      return "m4a"
    }
    if bytes.count >= 4, bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 {
      return "ogg"
    }

    return nil
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
}
