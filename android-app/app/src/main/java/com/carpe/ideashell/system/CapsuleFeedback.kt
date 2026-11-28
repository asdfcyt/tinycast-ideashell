package com.carpe.ideashell.system

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.carpe.ideashell.R

/** 语音胶囊的系统反馈：前台服务通知、熄屏守候通知、锁屏结果通知、震动。 */
private const val CHANNEL = "voice_capsule"
private const val CHANNEL_ARMED = "voice_capsule_armed"
private const val CHANNEL_RESULT = "voice_headless_result"
private const val RESULT_ID_BASE = 20_000
private const val NOTIFICATION_ID = 7301

// 震动节奏（关屏时没有画面，靠它知道到哪一步了）
internal val VIB_START = longArrayOf(0, 35)
internal val VIB_STOP = longArrayOf(0, 25)
internal val VIB_OK = longArrayOf(0, 30, 80, 30)
internal val VIB_ERROR = longArrayOf(0, 260)


/** 待机时的常驻通知（点「关闭」就关掉熄屏守候）。启动失败（系统不允许在后台起麦克风服务）返回 false */
internal fun VoiceCapsuleService.startArmedForeground(refreshOnly: Boolean = false): Boolean {
    val nm = getSystemService(NotificationManager::class.java)
    nm.createNotificationChannel(NotificationChannel(CHANNEL_ARMED, "熄屏守候", NotificationManager.IMPORTANCE_LOW))
    val off = PendingIntent.getService(
        this, 1, Intent(this, VoiceCapsuleService::class.java).setAction(VoiceCapsuleService.ACTION_DISARM),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    val key = settings.current.voiceKey
    val lockedKey = settings.current.voiceKeyLocked
    val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ARMED)
        .setSmallIcon(R.drawable.ic_stat_shiyi)
        .setContentTitle("拾忆 · 熄屏守候中")
        .setContentText(if (key == com.carpe.ideashell.data.settings.VoiceKey.OFF) "先在设置里选一个音量键" else "熄屏 / 锁屏后按住${lockedKey.label}说话，松手自动保存")
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .addAction(0, "关闭", off)
        .build()
    // 已经是前台服务了（录完回到待机）：只换通知，不重新走一遍 startForeground
    if (refreshOnly) {
        nm.notify(NOTIFICATION_ID, notification)
        return true
    }
    return runCatching {
        val type = if (Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
    }.onFailure {
        Toast.makeText(this, "没能启动熄屏守候：" + (it.message ?: ""), Toast.LENGTH_LONG).show()
    }.isSuccess
}

/** 没有画面时的结果：发一条通知，解锁后（锁屏上也看得到）能知道记下了什么，点开进拾忆 */
internal fun VoiceCapsuleService.postHeadlessResult(ok: Boolean, detail: String, searchQuery: String? = null, title: String? = null) {
    val nm = getSystemService(NotificationManager::class.java)
    nm.createNotificationChannel(
        NotificationChannel(CHANNEL_RESULT, "锁屏录音结果", NotificationManager.IMPORTANCE_DEFAULT).apply {
            setSound(null, null) // 已经震过了，通知本身不再响
            enableVibration(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        },
    )
    val open = PendingIntent.getActivity(
        this, if (searchQuery.isNullOrBlank()) 2 else 3 + (searchQuery.hashCode() and 0xFFFF),
        Intent(this, com.carpe.ideashell.ui.MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .apply { if (!searchQuery.isNullOrBlank()) putExtra(com.carpe.ideashell.ui.MainActivity.EXTRA_OPEN_SEARCH, searchQuery) },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    val notification = NotificationCompat.Builder(this, CHANNEL_RESULT)
        .setSmallIcon(R.drawable.ic_stat_shiyi)
        .setContentTitle(title ?: if (ok) "锁屏录音已保存" else "锁屏录音没成功")
        .setContentText(detail)
        .setStyle(NotificationCompat.BigTextStyle().bigText(detail))
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .setAutoCancel(true)
        .setContentIntent(open)
        .build()
    // 每次一个新 id：连续录几条不会互相覆盖
    runCatching { nm.notify(RESULT_ID_BASE + (System.currentTimeMillis() % 10_000).toInt(), notification) }
        .onFailure { android.util.Log.w("ShiyiKeys", "notify failed", it) }
}

internal fun VoiceCapsuleService.vibrate(pattern: LongArray) {
    val vibrator = if (Build.VERSION.SDK_INT >= 31) getSystemService(VibratorManager::class.java)?.defaultVibrator
    else getSystemService(Vibrator::class.java)
    // 用「闹钟」用途：熄屏 / 后台 / 静音模式下也会震
    @Suppress("DEPRECATION")
    vibrator?.vibrate(
        VibrationEffect.createWaveform(pattern, -1),
        AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build(),
    )
}

internal fun VoiceCapsuleService.startForegroundNow() {
    val nm = getSystemService(NotificationManager::class.java)
    nm.createNotificationChannel(NotificationChannel(CHANNEL, "语音记一条", NotificationManager.IMPORTANCE_LOW))
    val finish = PendingIntent.getService(
        this, 0, Intent(this, VoiceCapsuleService::class.java).setAction(VoiceCapsuleService.ACTION_FINISH),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    val notification: Notification = NotificationCompat.Builder(this, CHANNEL)
        .setSmallIcon(R.drawable.ic_stat_shiyi)
        .setContentTitle("拾忆 · 语音记一条")
        .setContentText("正在录音，说完点「完成」")
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .addAction(0, "完成", finish)
        .build()
    val type = if (Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
    ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
}
