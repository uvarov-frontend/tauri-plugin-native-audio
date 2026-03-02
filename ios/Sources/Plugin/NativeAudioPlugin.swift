import Foundation
import Tauri

class NativeAudioPlugin: Plugin, NativeAudioEventEmitter {
  private let runtime = PlaybackRuntimeActor.shared

  override init() {
    super.init()
    Task { @MainActor in
      await runtime.attachEmitter(self)
    }
  }

  deinit {
    let runtime = runtime
    Task {
      await runtime.attachEmitter(nil)
    }
  }

  func emitNativeAudioState(_ state: NativeAudioState) {
    try? trigger(nativeAudioStateEvent, data: state)
  }

  @objc public func initialize(_ invoke: Invoke) {
    Task { @MainActor in
      do {
        invoke.resolve(try await runtime.initialize())
      } catch {
        invoke.reject(error.localizedDescription)
      }
    }
  }

  @objc public func setSource(_ invoke: Invoke) {
    Task { @MainActor in
      do {
        let args = try invoke.parseArgs(SetSourceArgs.self)
        let src = args.src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty else {
          invoke.reject("src is required")
          return
        }

        invoke.resolve(
          try await runtime.setSource(
            src: src,
            id: args.id,
            title: args.title,
            artist: args.artist,
            artworkURL: args.artworkUrl
          )
        )
      } catch {
        invoke.reject(error.localizedDescription)
      }
    }
  }

  @objc public func play(_ invoke: Invoke) {
    Task { @MainActor in
      do {
        invoke.resolve(try await runtime.play())
      } catch {
        invoke.reject(error.localizedDescription)
      }
    }
  }

  @objc public func pause(_ invoke: Invoke) {
    Task { @MainActor in
      invoke.resolve(await runtime.pause())
    }
  }

  @objc public func seekTo(_ invoke: Invoke) {
    Task { @MainActor in
      do {
        let args = try invoke.parseArgs(SeekToArgs.self)
        guard let position = args.position, position.isFinite else {
          invoke.reject("position is required")
          return
        }

        invoke.resolve(await runtime.seekTo(position: position))
      } catch {
        invoke.reject(error.localizedDescription)
      }
    }
  }

  @objc public func setRate(_ invoke: Invoke) {
    Task { @MainActor in
      do {
        let args = try invoke.parseArgs(SetRateArgs.self)
        guard let rate = args.rate, rate.isFinite, rate > 0 else {
          invoke.reject("rate must be > 0")
          return
        }

        invoke.resolve(try await runtime.setRate(rate: rate))
      } catch {
        invoke.reject(error.localizedDescription)
      }
    }
  }

  @objc public func getState(_ invoke: Invoke) {
    Task { @MainActor in
      invoke.resolve(await runtime.getState())
    }
  }

  @objc public func getProgressCheckpoint(_ invoke: Invoke) {
    Task { @MainActor in
      invoke.resolve(await runtime.getProgressCheckpoint())
    }
  }

  @objc public func clearProgressCheckpoint(_ invoke: Invoke) {
    Task { @MainActor in
      await runtime.clearProgressCheckpoint()
      invoke.resolve()
    }
  }

  @objc public func dispose(_ invoke: Invoke) {
    Task { @MainActor in
      await runtime.dispose()
      invoke.resolve()
    }
  }
}

extension NativeAudioPlugin: @unchecked Sendable {}

@_cdecl("init_plugin_native_audio")
func initPlugin() -> Plugin {
  NativeAudioPlugin()
}
