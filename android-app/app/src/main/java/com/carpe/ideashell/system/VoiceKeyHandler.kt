package com.carpe.ideashell.system

import android.accessibilityservice.AccessibilityService
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.KeyEvent
import android.widget.Toast
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.data.settings.VoiceKey

/**
 * 音量键按住说话：在设置里选了音量上 / 下键之后，长按这个键就浮出录音胶囊开始录音，松手结束并处理。
 * 只接管设置里选的那个音量键；轻按（不到长按时间）仍然照常调音量；不读取屏幕内容。
 *
 * 不是单独的无障碍服务：并进统一的 [ExcerptService]，由它把按键事件转给 [onKeyEvent]。
 *
 * 系统交给无障碍服务的按键里没有「长按连发」，只有按下和抬起两个事件，所以长按要自己计时：
 * 按下就先吞掉，到了长按时间还没抬起就开始录音；抬起得早，就当作一次轻按，手动调一格音量。
 */
class VoiceKeyHandler(private val service: AccessibilityService) {

    private val handler = Handler(Looper.getMainLooper())

    /** 当前这次按键是否还按着 */
    private var pressing = false

    /** 这次按住是不是已经接管（开始了录音） */
    private var holding = false

    private val startHold = Runnable {
        if (!pressing) return@Runnable
        if (!canStart()) return@Runnable // 没条件录音：抬起时当作轻按调音量
        holding = true
        runCatching { VoiceCapsuleService.startHold(service) }.onFailure {
            holding = false
            Toast.makeText(service, "系统不允许在后台开始录音：" + (it.message ?: ""), Toast.LENGTH_LONG).show()
        }
    }

    /** 返回 true 表示这个按键被接管（吞掉） */
    fun onKeyEvent(event: KeyEvent): Boolean {
        val key = (service.application as IdeashellApp).container.settings.current.voiceKey
        if (key == VoiceKey.OFF || event.keyCode != key.keyCode) return false
        when (event.action) {
            KeyEvent.ACTION_DOWN -> {
                if (event.repeatCount == 0 && !pressing) {
                    pressing = true
                    holding = false
                    handler.postDelayed(startHold, LONG_PRESS_MS)
                }
            }
            KeyEvent.ACTION_UP -> {
                handler.removeCallbacks(startHold)
                val wasHolding = holding
                val wasPressing = pressing
                pressing = false
                holding = false
                if (wasHolding) {
                    VoiceCapsuleService.releaseHold()
                } else if (wasPressing) {
                    adjustVolume(key)
                }
            }
        }
        return true
    }

    /** 轻按：补上被吞掉的这一次音量调整 */
    private fun adjustVolume(key: VoiceKey) {
        val direction = if (key == VoiceKey.VOLUME_UP) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER
        service.getSystemService(AudioManager::class.java)
            ?.adjustSuggestedStreamVolume(direction, AudioManager.USE_DEFAULT_STREAM_TYPE, AudioManager.FLAG_SHOW_UI)
    }

    private fun canStart(): Boolean {
        if (service.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            Toast.makeText(service, "先在拾忆里开一次语音输入，授予麦克风权限", Toast.LENGTH_LONG).show()
            return false
        }
        if (!Settings.canDrawOverlays(service)) {
            Toast.makeText(service, "需要先开启拾忆的「显示在其他应用上层」权限", Toast.LENGTH_LONG).show()
            return false
        }
        return true
    }

    private companion object {
        /** 按住多久算长按 */
        const val LONG_PRESS_MS = 350L
    }
}
