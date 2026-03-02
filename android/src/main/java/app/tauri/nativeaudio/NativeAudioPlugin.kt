package app.tauri.nativeaudio

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.SharedPreferences
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.app.ActivityManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import kotlin.math.max

private const val TAG = "plugin/native-audio"
private const val EVENT_STATE = "native_audio_state"
private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 9512
private const val FOREGROUND_PROGRESS_TICK_MS = 25L
private const val BACKGROUND_PROGRESS_TICK_MS = 250L
private const val SEEK_INCREMENT_MS = 10_000L
private const val SEEK_STATE_STALE_MS = 1_500L
private const val PROGRESS_PERSIST_THROTTLE_MS = 1_000L
private const val PROGRESS_NEAR_START_EPSILON_SEC = 0.25
private const val PROGRESS_PERSIST_EPSILON_SEC = 0.05
private const val PROGRESS_PREFS_NAME = "tauri_native_audio_progress"
private const val PROGRESS_KEY_STORY_ID = "story_id"
private const val PROGRESS_KEY_CURRENT_TIME = "current_time"
private const val PROGRESS_KEY_UPDATED_AT_MS = "updated_at_ms"
private const val PROGRESS_KEY_STATUS = "status"

data class NativeAudioState(
    val status: String,
    val currentTime: Double,
    val duration: Double,
    val isPlaying: Boolean,
    val buffering: Boolean,
    val rate: Double,
    val error: String? = null,
)

data class NativeAudioProgressCheckpoint(
    val id: Long,
    val currentTime: Double,
    val updatedAtMs: Long,
    val status: String? = null,
)

@InvokeArg
class SetSourceArgs {
    var src: String? = null
    var id: Long? = null
    var title: String? = null
    var artist: String? = null
    var artworkUrl: String? = null
}

@InvokeArg
class SeekToArgs {
    var position: Double? = null
}

@InvokeArg
class SetRateArgs {
    var rate: Double? = null
}

private data class PendingSeekState(
    val shouldResume: Boolean,
    val startedAtMs: Long,
)

object NativeAudioRuntime {
    private val lock = Any()
    private val tickHandler = Handler(Looper.getMainLooper())
    private var tickScheduled = false

    private var player: ExoPlayer? = null
    private var appContext: Context? = null
    private var mediaSession: MediaSession? = null
    private var mediaSessionPlayer: Player? = null
    private var lastError: String? = null
    private var pendingSeekState: PendingSeekState? = null
    private var currentStoryId: Long? = null
    private var lastProgressPersistedAtMs = 0L
    private var lastProgressPersistedStoryId: Long? = null
    private var lastProgressPersistedTimeSec: Double? = null

    private val tickRunnable = object : Runnable {
        override fun run() {
            val shouldContinue = synchronized(lock) {
                val snapshot = snapshotLocked()
                appContext?.let { persistProgressCheckpointLocked(it, snapshot, force = false) }
                NativeAudioPlugin.emitToActive(snapshot)
                val isPlaying = player?.isPlaying == true
                tickScheduled = isPlaying
                isPlaying
            }
            if (shouldContinue) {
                val delay = synchronized(lock) { nextProgressTickDelayLocked() }
                tickHandler.postDelayed(this, delay)
            }
        }
    }

    private val playerListener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_ENDED) {
                synchronized(lock) {
                    appContext?.let { persistProgressCheckpointLocked(it, snapshotLocked(), force = true) }
                }
            }
            syncTicking()
            emitState()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            syncTicking()
            emitState()
        }

        override fun onPlaybackParametersChanged(playbackParameters: androidx.media3.common.PlaybackParameters) {
            emitState()
        }

        override fun onPositionDiscontinuity(
            oldPosition: Player.PositionInfo,
            newPosition: Player.PositionInfo,
            reason: Int,
        ) {
            if (reason == Player.DISCONTINUITY_REASON_SEEK || reason == Player.DISCONTINUITY_REASON_SEEK_ADJUSTMENT) {
                synchronized(lock) {
                    val exoPlayer = player ?: return@synchronized
                    val pendingSeek = pendingSeekState
                    val shouldResume = pendingSeek?.shouldResume ?: exoPlayer.playWhenReady
                    if (!shouldResume && exoPlayer.playWhenReady) exoPlayer.pause()
                    val shouldRecoverPlayback =
                        shouldResume &&
                            !exoPlayer.isPlaying &&
                            exoPlayer.playbackState == Player.STATE_READY &&
                            lastError == null
                    if (shouldRecoverPlayback) exoPlayer.play()
                    appContext?.let { persistProgressCheckpointLocked(it, snapshotLocked(), force = true) }
                }
            }
            syncTicking()
            emitState()
        }

        override fun onPlayerError(error: PlaybackException) {
            Log.e(TAG, "onPlayerError code=${error.errorCodeName} message=${error.message}", error)
            synchronized(lock) {
                lastError = error.message ?: "unknown"
                pendingSeekState = null
            }
            syncTicking()
            emitState()
        }
    }

    fun ensure(context: Context) {
        synchronized(lock) {
            if (player != null && mediaSession != null) return

            val ctx = context.applicationContext
            appContext = ctx

            val audioAttributes = AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                .build()

            val exoPlayer = ExoPlayer.Builder(ctx)
                .setSeekBackIncrementMs(SEEK_INCREMENT_MS)
                .setSeekForwardIncrementMs(SEEK_INCREMENT_MS)
                .build()
            exoPlayer.setAudioAttributes(audioAttributes, true)
            exoPlayer.setHandleAudioBecomingNoisy(true)
            exoPlayer.setWakeMode(C.WAKE_MODE_LOCAL)
            exoPlayer.addListener(playerListener)
            player = exoPlayer
            mediaSessionPlayer = object : ForwardingPlayer(exoPlayer) {
                override fun getAvailableCommands(): Player.Commands {
                    return super.getAvailableCommands()
                        .buildUpon()
                        .add(Player.COMMAND_SEEK_BACK)
                        .add(Player.COMMAND_SEEK_FORWARD)
                        .add(Player.COMMAND_SEEK_TO_PREVIOUS)
                        .add(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
                        .add(Player.COMMAND_SEEK_TO_NEXT)
                        .add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
                        .build()
                }

                override fun isCommandAvailable(command: Int): Boolean {
                    if (command == Player.COMMAND_SEEK_BACK || command == Player.COMMAND_SEEK_FORWARD) return true
                    if (command == Player.COMMAND_SEEK_TO_PREVIOUS || command == Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM) return true
                    if (command == Player.COMMAND_SEEK_TO_NEXT || command == Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM) return true
                    return super.isCommandAvailable(command)
                }

                override fun seekToPrevious() {
                    exoPlayer.seekBack()
                }

                override fun seekToPreviousMediaItem() {
                    exoPlayer.seekBack()
                }

                override fun seekToNext() {
                    exoPlayer.seekForward()
                }

                override fun seekToNextMediaItem() {
                    exoPlayer.seekForward()
                }
            }

            val launchIntent = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            val pendingIntent = launchIntent?.let {
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
                PendingIntent.getActivity(ctx, 0, it, flags)
            }

            val sessionPlayer = mediaSessionPlayer ?: exoPlayer
            mediaSession = MediaSession.Builder(ctx, sessionPlayer)
                .apply {
                    if (pendingIntent != null) setSessionActivity(pendingIntent)
                }
                .build()

            lastError = null
            syncTickingLocked()
        }
    }

    fun initialize(context: Context) {
        ensure(context)
        emitState()
    }

    fun startService(context: Context) {
        val serviceIntent = Intent(context.applicationContext, NativeAudioService::class.java)
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.applicationContext.startForegroundService(serviceIntent)
            } else {
                context.applicationContext.startService(serviceIntent)
            }
        }.onFailure { error ->
            Log.w(TAG, "startService failed", error)
        }
    }

    fun stopService(context: Context) {
        val serviceIntent = Intent(context.applicationContext, NativeAudioService::class.java)
        context.applicationContext.stopService(serviceIntent)
    }

    fun setSource(context: Context, src: String, storyId: Long?, title: String?, artist: String?, artworkUrl: String?) {
        synchronized(lock) {
            ensure(context)
            val exoPlayer = player ?: return

            val mediaItem = buildMediaItem(src, title, artist, artworkUrl)

            pendingSeekState = null
            currentStoryId = storyId?.takeIf { it > 0 }
            exoPlayer.setMediaItem(mediaItem)
            exoPlayer.prepare()
            lastError = null
            syncTickingLocked()
        }
        emitState()
    }

    fun play(context: Context) {
        startService(context)
        synchronized(lock) {
            ensure(context)
            val exoPlayer = player ?: return
            if (exoPlayer.playbackState == Player.STATE_ENDED) {
                exoPlayer.seekTo(0L)
            }
            pendingSeekState = null
            exoPlayer.playWhenReady = true
            exoPlayer.play()
            lastError = null
            syncTickingLocked()
        }
        emitState()
    }

    fun pause(context: Context) {
        synchronized(lock) {
            ensure(context)
            pendingSeekState = null
            player?.pause()
            syncTickingLocked()
            persistProgressCheckpointLocked(context.applicationContext, snapshotLocked(), force = true)
        }
        emitState()
    }

    fun seekTo(context: Context, positionSec: Double) {
        if (!positionSec.isFinite()) return
        synchronized(lock) {
            ensure(context)
            val safeMs = max(0L, (positionSec * 1000.0).toLong())
            val exoPlayer = player ?: return@synchronized
            val shouldResume = exoPlayer.playWhenReady || exoPlayer.isPlaying
            pendingSeekState = PendingSeekState(shouldResume = shouldResume, startedAtMs = System.currentTimeMillis())
            if (!shouldResume && exoPlayer.playWhenReady) exoPlayer.pause()
            exoPlayer.seekTo(safeMs)
        }
        emitState()
    }

    fun setRate(context: Context, rate: Double) {
        if (!rate.isFinite() || rate <= 0.0) return
        synchronized(lock) {
            ensure(context)
            player?.setPlaybackSpeed(rate.toFloat())
        }
        emitState()
    }

    fun getState(context: Context): NativeAudioState {
        synchronized(lock) {
            ensure(context)
            return snapshotLocked()
        }
    }

    fun getProgressCheckpoint(context: Context): NativeAudioProgressCheckpoint? {
        val prefs = progressPrefs(context.applicationContext)
        val storyId = prefs.getLong(PROGRESS_KEY_STORY_ID, 0L)
        if (storyId <= 0L) return null
        val currentTime = prefs.getFloat(PROGRESS_KEY_CURRENT_TIME, 0f).toDouble()
        val updatedAtMs = prefs.getLong(PROGRESS_KEY_UPDATED_AT_MS, 0L)
        if (!currentTime.isFinite() || currentTime <= 0.0 || updatedAtMs <= 0L) return null
        val status = prefs.getString(PROGRESS_KEY_STATUS, null)
        return NativeAudioProgressCheckpoint(
            id = storyId,
            currentTime = currentTime,
            updatedAtMs = updatedAtMs,
            status = status,
        )
    }

    fun clearProgressCheckpoint(context: Context) {
        synchronized(lock) {
            progressPrefs(context.applicationContext).edit()
                .remove(PROGRESS_KEY_STORY_ID)
                .remove(PROGRESS_KEY_CURRENT_TIME)
                .remove(PROGRESS_KEY_UPDATED_AT_MS)
                .remove(PROGRESS_KEY_STATUS)
                .apply()
            lastProgressPersistedAtMs = 0L
            lastProgressPersistedStoryId = null
            lastProgressPersistedTimeSec = null
        }
    }

    fun dispose(context: Context) {
        synchronized(lock) {
            persistProgressCheckpointLocked(context.applicationContext, snapshotLocked(), force = true)
            tickHandler.removeCallbacks(tickRunnable)
            tickScheduled = false

            player?.removeListener(playerListener)
            player?.release()
            player = null

            mediaSession?.release()
            mediaSession = null
            mediaSessionPlayer = null

            lastError = null
            pendingSeekState = null
            currentStoryId = null
            appContext = null
        }
        stopService(context)
        emitState()
    }

    fun mediaSession(): MediaSession? {
        synchronized(lock) {
            return mediaSession
        }
    }

    fun mediaSessionPlayer(): Player? {
        synchronized(lock) {
            return mediaSessionPlayer ?: player
        }
    }

    private fun syncTicking() {
        synchronized(lock) {
            syncTickingLocked()
        }
    }

    private fun syncTickingLocked() {
        val isPlaying = player?.isPlaying == true
        if (isPlaying && !tickScheduled) {
            tickScheduled = true
            tickHandler.removeCallbacks(tickRunnable)
            tickHandler.post(tickRunnable)
            return
        }
        if (!isPlaying && tickScheduled) {
            tickScheduled = false
            tickHandler.removeCallbacks(tickRunnable)
        }
    }

    private fun nextProgressTickDelayLocked(): Long {
        val context = appContext ?: return BACKGROUND_PROGRESS_TICK_MS
        val isForeground = isAppInForeground()
        val isInteractive = isDeviceInteractive(context)
        return if (isForeground && isInteractive) FOREGROUND_PROGRESS_TICK_MS else BACKGROUND_PROGRESS_TICK_MS
    }

    private fun isAppInForeground(): Boolean {
        val processInfo = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(processInfo)
        return processInfo.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND ||
            processInfo.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
    }

    private fun isDeviceInteractive(context: Context): Boolean {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return powerManager?.isInteractive ?: true
    }

    private fun emitState() {
        val snapshot = synchronized(lock) { snapshotLocked() }
        NativeAudioPlugin.emitToActive(snapshot)
    }

    private fun progressPrefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PROGRESS_PREFS_NAME, Context.MODE_PRIVATE)

    private fun persistProgressCheckpointLocked(context: Context, snapshot: NativeAudioState, force: Boolean) {
        val storyId = currentStoryId ?: return
        if (storyId <= 0L) return
        if (!snapshot.currentTime.isFinite() || snapshot.currentTime <= PROGRESS_NEAR_START_EPSILON_SEC) return

        val now = System.currentTimeMillis()
        if (!force && now - lastProgressPersistedAtMs < PROGRESS_PERSIST_THROTTLE_MS) return

        val prevStoryId = lastProgressPersistedStoryId
        val prevTime = lastProgressPersistedTimeSec
        if (!force && prevStoryId == storyId && prevTime != null && kotlin.math.abs(prevTime - snapshot.currentTime) <= PROGRESS_PERSIST_EPSILON_SEC) {
            return
        }

        progressPrefs(context).edit()
            .putLong(PROGRESS_KEY_STORY_ID, storyId)
            .putFloat(PROGRESS_KEY_CURRENT_TIME, snapshot.currentTime.toFloat())
            .putLong(PROGRESS_KEY_UPDATED_AT_MS, now)
            .putString(PROGRESS_KEY_STATUS, snapshot.status)
            .apply()

        lastProgressPersistedAtMs = now
        lastProgressPersistedStoryId = storyId
        lastProgressPersistedTimeSec = snapshot.currentTime
    }

    private fun buildMediaItem(src: String, title: String?, artist: String?, artworkUrl: String?): MediaItem {
        val metadataBuilder = MediaMetadata.Builder()
        if (!title.isNullOrBlank()) metadataBuilder.setTitle(title)
        if (!artist.isNullOrBlank()) metadataBuilder.setArtist(artist)
        if (!artworkUrl.isNullOrBlank()) {
            runCatching { Uri.parse(artworkUrl) }
                .onSuccess { metadataBuilder.setArtworkUri(it) }
        }
        return MediaItem.Builder()
            .setUri(src)
            .setMediaMetadata(metadataBuilder.build())
            .build()
    }

    private fun snapshotLocked(): NativeAudioState {
        val exoPlayer = player
            ?: return NativeAudioState(
                status = "idle",
                currentTime = 0.0,
                duration = 0.0,
                isPlaying = false,
                buffering = false,
                rate = 1.0,
                error = null,
            )

        val rawDurationMs = exoPlayer.duration
        val durationMs = if (rawDurationMs > 0) rawDurationMs else 0L
        val currentMs = max(0L, exoPlayer.currentPosition)
        val buffering = exoPlayer.playbackState == Player.STATE_BUFFERING

        val seekState = activeSeekStateLocked()
        if (seekState?.shouldResume == true && exoPlayer.isPlaying) pendingSeekState = null

        val hasTerminalState = lastError != null || exoPlayer.playbackState == Player.STATE_ENDED
        if (hasTerminalState) pendingSeekState = null
        val effectiveIsPlaying = if (hasTerminalState) false else (seekState?.shouldResume ?: exoPlayer.isPlaying)
        val effectiveBuffering = if (hasTerminalState || seekState?.shouldResume == false) false else buffering

        val status = when {
            lastError != null -> "error"
            exoPlayer.playbackState == Player.STATE_ENDED -> "ended"
            seekState?.shouldResume == true -> "playing"
            effectiveBuffering -> "loading"
            effectiveIsPlaying -> "playing"
            else -> "idle"
        }

        return NativeAudioState(
            status = status,
            currentTime = currentMs / 1000.0,
            duration = durationMs / 1000.0,
            isPlaying = effectiveIsPlaying,
            buffering = effectiveBuffering,
            rate = exoPlayer.playbackParameters.speed.toDouble(),
            error = lastError,
        )
    }

    private fun activeSeekStateLocked(): PendingSeekState? {
        val seekState = pendingSeekState ?: return null
        val now = System.currentTimeMillis()
        if (now - seekState.startedAtMs > SEEK_STATE_STALE_MS) {
            pendingSeekState = null
            return null
        }
        return seekState
    }
}

@TauriPlugin
class NativeAudioPlugin(private val activity: Activity) : Plugin(activity) {

    init {
        activeInstance = this
    }

    @Command
    fun initialize(invoke: Invoke) {
        requestNotificationPermission()
        runCatching {
            NativeAudioRuntime.initialize(activity.applicationContext)
        }.onSuccess {
            invoke.resolve(toJsObject(NativeAudioRuntime.getState(activity.applicationContext)))
        }.onFailure {
            invoke.reject(it.message ?: "initialize failed")
        }
    }

    @Command
    fun register_listener(invoke: Invoke) {
        invoke.resolve()
    }

    @Command
    fun remove_listener(invoke: Invoke) {
        invoke.resolve()
    }

    @Command
    fun setSource(invoke: Invoke) {
        val args = invoke.parseArgs(SetSourceArgs::class.java)
        val src = args.src?.trim().orEmpty()
        if (src.isEmpty()) {
            invoke.reject("src is required")
            return
        }

        runCatching {
            NativeAudioRuntime.setSource(activity.applicationContext, src, args.id, args.title, args.artist, args.artworkUrl)
        }.onSuccess {
            invoke.resolve(toJsObject(NativeAudioRuntime.getState(activity.applicationContext)))
        }.onFailure {
            invoke.reject(it.message ?: "setSource failed")
        }
    }

    @Command
    fun play(invoke: Invoke) {
        runCatching {
            NativeAudioRuntime.play(activity.applicationContext)
        }.onSuccess {
            invoke.resolve(toJsObject(NativeAudioRuntime.getState(activity.applicationContext)))
        }.onFailure {
            invoke.reject(it.message ?: "play failed")
        }
    }

    @Command
    fun pause(invoke: Invoke) {
        runCatching {
            NativeAudioRuntime.pause(activity.applicationContext)
        }.onSuccess {
            invoke.resolve(toJsObject(NativeAudioRuntime.getState(activity.applicationContext)))
        }.onFailure {
            invoke.reject(it.message ?: "pause failed")
        }
    }

    @Command
    fun seekTo(invoke: Invoke) {
        val args = invoke.parseArgs(SeekToArgs::class.java)
        val position = args.position
        if (position == null || !position.isFinite()) {
            invoke.reject("position is required")
            return
        }

        runCatching {
            NativeAudioRuntime.seekTo(activity.applicationContext, position)
        }.onSuccess {
            invoke.resolve(toJsObject(NativeAudioRuntime.getState(activity.applicationContext)))
        }.onFailure {
            invoke.reject(it.message ?: "seekTo failed")
        }
    }

    @Command
    fun setRate(invoke: Invoke) {
        val args = invoke.parseArgs(SetRateArgs::class.java)
        val rate = args.rate
        if (rate == null || !rate.isFinite() || rate <= 0) {
            invoke.reject("rate must be > 0")
            return
        }

        runCatching {
            NativeAudioRuntime.setRate(activity.applicationContext, rate)
        }.onSuccess {
            invoke.resolve(toJsObject(NativeAudioRuntime.getState(activity.applicationContext)))
        }.onFailure {
            invoke.reject(it.message ?: "setRate failed")
        }
    }

    @Command
    fun getState(invoke: Invoke) {
        runCatching {
            NativeAudioRuntime.getState(activity.applicationContext)
        }.onSuccess {
            invoke.resolve(toJsObject(it))
        }.onFailure {
            invoke.reject(it.message ?: "getState failed")
        }
    }

    @Command
    fun getProgressCheckpoint(invoke: Invoke) {
        runCatching {
            NativeAudioRuntime.getProgressCheckpoint(activity.applicationContext)
        }.onSuccess {
            invoke.resolve(it?.let { checkpoint -> toJsObject(checkpoint) })
        }.onFailure {
            invoke.reject(it.message ?: "getProgressCheckpoint failed")
        }
    }

    @Command
    fun clearProgressCheckpoint(invoke: Invoke) {
        runCatching {
            NativeAudioRuntime.clearProgressCheckpoint(activity.applicationContext)
        }.onSuccess {
            invoke.resolve()
        }.onFailure {
            invoke.reject(it.message ?: "clearProgressCheckpoint failed")
        }
    }

    @Command
    fun dispose(invoke: Invoke) {
        runCatching {
            NativeAudioRuntime.dispose(activity.applicationContext)
        }.onSuccess {
            invoke.resolve()
        }.onFailure {
            invoke.reject(it.message ?: "dispose failed")
        }
    }

    override fun onDestroy() {
        if (activeInstance === this) activeInstance = null
        super.onDestroy()
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE,
        )
    }

    private fun emitState(state: NativeAudioState) {
        val payload = toJsObject(state)
        activity.runOnUiThread {
            trigger(EVENT_STATE, payload)
        }
    }

    private fun toJsObject(state: NativeAudioState): JSObject {
        val payload = JSObject()
        payload.put("status", state.status)
        payload.put("currentTime", state.currentTime)
        payload.put("duration", state.duration)
        payload.put("isPlaying", state.isPlaying)
        payload.put("buffering", state.buffering)
        payload.put("rate", state.rate)
        if (!state.error.isNullOrBlank()) payload.put("error", state.error)
        return payload
    }

    private fun toJsObject(checkpoint: NativeAudioProgressCheckpoint): JSObject {
        val payload = JSObject()
        payload.put("id", checkpoint.id)
        payload.put("currentTime", checkpoint.currentTime)
        payload.put("updatedAtMs", checkpoint.updatedAtMs)
        if (!checkpoint.status.isNullOrBlank()) payload.put("status", checkpoint.status)
        return payload
    }

    companion object {
        @Volatile
        private var activeInstance: NativeAudioPlugin? = null

        internal fun emitToActive(state: NativeAudioState) {
            activeInstance?.emitState(state)
        }
    }
}
