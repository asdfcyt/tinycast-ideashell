package com.carpe.ideashell.system

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.view.KeyEvent
import androidx.core.content.ContextCompat
import com.carpe.ideashell.data.settings.SettingsStore
import com.carpe.ideashell.data.settings.VoiceKey

/**
 * 熄屏时接管音量键 / 耳机键。
 *
 * 熄屏后系统不再把音量键交给无障碍服务（`AccessibilityInputFilter` 只处理带 `FLAG_PASS_TO_USER` 的按键，
 * 熄屏时的音量键没有这个标志），唯一的通路是「当前在播放的媒体会话」：
 * 熄屏时让一个使用远程音量（`VolumeProvider`）的 `MediaSession` 处于「播放中」，系统就会把音量键变成 [VolumeProvider.onAdjustVolume]：
 * 按下 = 方向（`ADJUST_LOWER` / `ADJUST_RAISE`），抬起 = `ADJUST_SAME`；没有长按连发，所以按住时长要自己计。
 * 亮屏时关掉会话，按键交回给无障碍服务（[VoiceKeyHandler]）。
 *
 * 别的 App 正在放音乐时系统会优先把音量键给音乐，这里收不到，也不去抢；耳机键同理，放音乐时原样放行给音乐 App。
 *
 * 持有它的是 [VoiceCapsuleService]（守候模式下常驻的前台服务）：麦克风前台服务不能在后台新建，所以提前在前台启动好。
 */
class ScreenOffVoiceKeys(
    private val context: Context,
    private val settings: SettingsStore,
    /** 熄屏时按住音量键到了长按时间：开始录音 */
    private val onHoldStart: () -> Unit,
    /** 熄屏时音量键抬起（只在 [onHoldStart] 之后才会调）：结束录音 */
    private val onHoldEnd: () -> Unit,
    /** 耳机键：没在录就开始，在录就结束 */
    private val onToggle: () -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val audio = context.getSystemService(AudioManager::class.java)
    private var session: MediaSession? = null
    private var active = false
    private var passingThrough = false

    private var pressing = false
    private var holding = false
    private var otherDown = false
    private var lastTapAt = 0L

    private val startHold = Runnable {
        if (!pressing) return@Runnable
        holding = true
        onHoldStart()
    }

    private val reactivate = Runnable {
        passingThrough = false
        if (!isInteractive()) activate()
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> activate()
                Intent.ACTION_SCREEN_ON -> deactivate()
            }
        }
    }

    private val volume = object : VolumeProvider(VOLUME_CONTROL_RELATIVE, 100, 50) {
        override fun onAdjustVolume(direction: Int) = onVolumeKey(direction)
    }

    fun start() {
        if (session != null) return
        val s = MediaSession(context, "ShiyiVoiceKeys")
        s.setCallback(object : MediaSession.Callback() {
            override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean = onMediaButton(mediaButtonIntent)
        })
        s.setPlaybackToRemote(volume)
        session = s
        ContextCompat.registerReceiver(
            context,
            screenReceiver,
            IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
            },
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        if (!isInteractive()) activate()
    }

    fun stop() {
        handler.removeCallbacksAndMessages(null)
        runCatching { context.unregisterReceiver(screenReceiver) }
        deactivate()
        session?.release()
        session = null
    }

    private fun isInteractive(): Boolean = context.getSystemService(PowerManager::class.java)?.isInteractive != false

    /** 熄屏：让会话处于「播放中」，系统才会把音量键 / 耳机键交给它 */
    private fun activate() {
        val s = session ?: return
        if (active) return
        active = true
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE)
                .setState(PlaybackState.STATE_PLAYING, 0L, 1f)
                .build(),
        )
        s.isActive = true
    }

    /** 亮屏：关掉会话，按键回到无障碍服务；正按着的话直接结束这次录音 */
    private fun deactivate() {
        handler.removeCallbacks(startHold)
        val wasHolding = holding
        pressing = false
        holding = false
        otherDown = false
        if (wasHolding) onHoldEnd()
        if (!active) return
        active = false
        session?.let {
            it.isActive = false
            it.setPlaybackState(PlaybackState.Builder().setState(PlaybackState.STATE_NONE, 0L, 0f).build())
        }
    }

    /** 熄屏时的音量键：只认设置里选的那个键 */
    private fun onVolumeKey(direction: Int) {
        val key = settings.current.voiceKey
        if (key == VoiceKey.OFF) return
        val mine = if (key == VoiceKey.VOLUME_UP) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER
        when (direction) {
            AudioManager.ADJUST_SAME -> {
                // 抬起
                if (otherDown) {
                    // 另一个音量键的抬起：熄屏时不处理
                    otherDown = false
                    return
                }
                if (!pressing) {
                    // 没收到「按下」就收到了「抬起」：这类手机（如荣耀）熄屏时系统自己吃掉了音量下键的按下，只把抬起转给媒体会话，
                    // 没法判断按了多久，退而求其次当作「轻按」：按一下开始录音，再按一下结束。
                    // 同一次抬起系统可能转发两次，所以做个去抖
                    val now = SystemClock.uptimeMillis()
                    if (now - lastTapAt < TAP_DEBOUNCE_MS) return
                    lastTapAt = now
                    onToggle()
                    return
                }
                handler.removeCallbacks(startHold)
                val wasHolding = holding
                pressing = false
                holding = false
                if (wasHolding) onHoldEnd()
            }
            mine -> if (!pressing) {
                pressing = true
                holding = false
                handler.postDelayed(startHold, LONG_PRESS_MS)
            }
            // 另一个音量键的按下：记一下，等它抬起时别当成「没有按下的抬起」
            else -> otherDown = true
        }
    }

    /** 耳机线控 / 蓝牙耳机的播放键 */
    private fun onMediaButton(intent: Intent): Boolean {
        @Suppress("DEPRECATION")
        val event = intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT) ?: return false
        // 正在放音乐：原样放行给音乐 App（先让出会话，再把这个键重新发出去）
        if (passingThrough || audio?.isMusicActive == true || !settings.current.voiceHeadsetKey) {
            passThrough(event)
            return true
        }
        val code = event.keyCode
        if (code == KeyEvent.KEYCODE_HEADSETHOOK || code == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE ||
            code == KeyEvent.KEYCODE_MEDIA_PLAY || code == KeyEvent.KEYCODE_MEDIA_PAUSE
        ) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) onToggle()
            return true
        }
        passThrough(event)
        return true
    }

    private fun passThrough(event: KeyEvent) {
        passingThrough = true
        deactivate()
        audio?.dispatchMediaKeyEvent(event)
        handler.removeCallbacks(reactivate)
        handler.postDelayed(reactivate, 600)
    }

    private companion object {
        /** 按住多久算长按（和亮屏时 [VoiceKeyHandler] 一致） */
        const val LONG_PRESS_MS = 350L

        /** 「只有抬起」的轻按去抖 */
        const val TAP_DEBOUNCE_MS = 500L
    }
}
