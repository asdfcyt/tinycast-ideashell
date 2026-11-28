package com.carpe.ideashell.data.assistant

import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.net.Uri
import android.provider.Settings
import com.carpe.ideashell.system.DndResetWorker
import com.carpe.ideashell.system.ExcerptService
import kotlin.math.roundToInt

/**
 * 助手能直接动手的设备控制：勿扰 / 铃声模式 / 音量 / 亮度 / 手电筒 / 打开应用 / 打开系统设置页。
 * 每个都返回一句给人看的结果（成功或失败原因），不抛异常。
 * 需要用户在系统里另外授权的（勿扰、修改系统设置）：没授权时自动打开对应的授权页，并说明要在哪里打开。
 * 从后台启动页面时，优先借无障碍服务的身份（系统允许它从后台打开界面）。
 */
object DeviceControl {

    // ───────────────────────── 权限状态（设置页也用） ─────────────────────────

    /** 有没有「勿扰」权限（系统设置 → 勿扰权限 / 通知管理 里给拾忆打开） */
    fun dndAccessGranted(context: Context): Boolean =
        runCatching { context.getSystemService(NotificationManager::class.java).isNotificationPolicyAccessGranted }.getOrDefault(false)

    /** 有没有「修改系统设置」权限（调亮度要用） */
    fun writeSettingsGranted(context: Context): Boolean = runCatching { Settings.System.canWrite(context) }.getOrDefault(false)

    /** 打开勿扰权限页；打不开就回退到应用详情 */
    fun openDndAccess(context: Context) {
        if (!start(context, Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))) openAppDetails(context)
    }

    fun openWriteSettings(context: Context) {
        val intent = Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:${context.packageName}"))
        if (!start(context, intent)) openAppDetails(context)
    }

    private fun openAppDetails(context: Context) {
        start(context, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
    }

    // ───────────────────────── 勿扰 / 铃声 ─────────────────────────

    /**
     * [mode]：off 关闭勿扰 / priority 只允许重要提醒（闹钟、星标联系人等，系统设置里可调）/ alarms 只允许闹钟 / silence 完全静音。
     * [minutes]：大于 0 时，到点自动关掉勿扰（不填就一直开着）。
     */
    fun setDnd(context: Context, mode: String, minutes: Int?): String {
        val filter = when (mode) {
            "off" -> NotificationManager.INTERRUPTION_FILTER_ALL
            "priority" -> NotificationManager.INTERRUPTION_FILTER_PRIORITY
            "alarms" -> NotificationManager.INTERRUPTION_FILTER_ALARMS
            "silence" -> NotificationManager.INTERRUPTION_FILTER_NONE
            else -> return "mode 只能是 off / priority / alarms / silence"
        }
        if (!dndAccessGranted(context)) {
            openDndAccess(context)
            return "还没有「勿扰」权限：已打开系统的权限页，请在列表里给「拾忆」打开，然后再说一次（也可以在 设置 → 语音助手 → 系统权限 里点「勿扰模式」）"
        }
        val nm = context.getSystemService(NotificationManager::class.java)
        return try {
            nm.setInterruptionFilter(filter)
            val label = when (mode) {
                "off" -> "已关闭勿扰模式"
                "priority" -> "已开启勿扰模式（只响重要提醒）"
                "alarms" -> "已开启勿扰模式（只响闹钟）"
                else -> "已开启勿扰模式（完全静音）"
            }
            val m = minutes?.takeIf { it in 1..1440 && mode != "off" }
            if (m != null) DndResetWorker.schedule(context, m) else DndResetWorker.cancel(context)
            if (m != null) "$label，${if (m % 60 == 0) "${m / 60} 小时" else "$m 分钟"}后自动关闭" else label
        } catch (e: SecurityException) {
            "系统不让拾忆改勿扰（${e.message ?: "没有权限"}），请在系统设置里检查勿扰权限"
        }
    }

    /** [mode]：normal 响铃 / vibrate 震动 / silent 静音（静音要有勿扰权限） */
    fun setRinger(context: Context, mode: String): String {
        val am = context.getSystemService(AudioManager::class.java) ?: return "没能调铃声模式"
        val target = when (mode) {
            "normal" -> AudioManager.RINGER_MODE_NORMAL
            "vibrate" -> AudioManager.RINGER_MODE_VIBRATE
            "silent" -> AudioManager.RINGER_MODE_SILENT
            else -> return "mode 只能是 normal / vibrate / silent"
        }
        if (target == AudioManager.RINGER_MODE_SILENT && !dndAccessGranted(context)) {
            openDndAccess(context)
            return "静音需要「勿扰」权限：已打开系统的权限页，请给「拾忆」打开后再说一次；现在可以先用「震动」"
        }
        return try {
            am.ringerMode = target
            when (target) {
                AudioManager.RINGER_MODE_NORMAL -> "已切到响铃模式"
                AudioManager.RINGER_MODE_VIBRATE -> "已切到震动模式"
                else -> "已切到静音模式"
            }
        } catch (e: SecurityException) {
            "系统不让拾忆改铃声模式（${e.message ?: "没有权限"}），请检查勿扰权限"
        }
    }

    // ───────────────────────── 音量 / 亮度 / 手电筒 ─────────────────────────

    /**
     * [stream]：media 媒体 / ring 铃声 / alarm 闹钟 / call 通话。
     * [action]：set（配合 [percent]）/ up / down / mute。
     */
    fun setVolume(context: Context, stream: String, action: String, percent: Int?): String {
        val am = context.getSystemService(AudioManager::class.java) ?: return "没能调音量"
        val (type, name) = when (stream) {
            "media" -> AudioManager.STREAM_MUSIC to "媒体音量"
            "ring" -> AudioManager.STREAM_RING to "铃声音量"
            "alarm" -> AudioManager.STREAM_ALARM to "闹钟音量"
            "call" -> AudioManager.STREAM_VOICE_CALL to "通话音量"
            else -> return "stream 只能是 media / ring / alarm / call"
        }
        val max = am.getStreamMaxVolume(type).coerceAtLeast(1)
        val cur = am.getStreamVolume(type)
        // 荣耀等手机的媒体音量有 160 档，按「一档」调几乎听不出变化：上 / 下调 1/8
        val step = (max / 8).coerceAtLeast(1)
        val next = when (action) {
            "set" -> ((percent ?: return "set 要给 percent（0~100）").coerceIn(0, 100) * max / 100.0).roundToInt()
            "up" -> cur + step
            "down" -> cur - step
            "mute" -> 0
            else -> return "action 只能是 set / up / down / mute"
        }.coerceIn(0, max)
        return try {
            am.setStreamVolume(type, next, AudioManager.FLAG_SHOW_UI)
            "$name 调到了 ${(next * 100.0 / max).roundToInt()}%"
        } catch (e: SecurityException) {
            if (type == AudioManager.STREAM_RING && !dndAccessGranted(context)) {
                openDndAccess(context)
                "调铃声音量需要「勿扰」权限：已打开系统的权限页，请给「拾忆」打开后再说一次"
            } else {
                "系统不让拾忆调$name（${e.message ?: "没有权限"}）"
            }
        }
    }

    /** [percent] 1~100；[auto] = true 时改回自动亮度 */
    fun setBrightness(context: Context, percent: Int?, auto: Boolean): String {
        if (!writeSettingsGranted(context)) {
            openWriteSettings(context)
            return "调亮度需要「修改系统设置」权限：已打开授权页，请给「拾忆」打开后再说一次"
        }
        val resolver = context.contentResolver
        return try {
            if (auto) {
                Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS_MODE, Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC)
                "已改回自动亮度"
            } else {
                val p = (percent ?: return "要给亮度百分比（1~100）或者 auto").coerceIn(1, 100)
                Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS_MODE, Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL)
                Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS, (p * 255 / 100.0).roundToInt().coerceIn(1, 255))
                "亮度调到了 $p%"
            }
        } catch (e: Exception) {
            "没能调亮度（${e.message ?: e.javaClass.simpleName}）"
        }
    }

    fun flashlight(context: Context, on: Boolean): String {
        val cm = context.getSystemService(CameraManager::class.java) ?: return "这台设备没有手电筒"
        return try {
            val id = cm.cameraIdList.firstOrNull { cid ->
                val c = cm.getCameraCharacteristics(cid)
                c.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true && c.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
            } ?: return "这台设备没有手电筒"
            cm.setTorchMode(id, on)
            if (on) "手电筒已打开" else "手电筒已关闭"
        } catch (e: Exception) {
            "没能${if (on) "打开" else "关闭"}手电筒（${e.message ?: e.javaClass.simpleName}）"
        }
    }

    // ───────────────────────── 打开应用 / 系统设置页 ─────────────────────────

    /** 按名字打开应用：名字完全一致的优先，其次包含这几个字的（取名字最短的那个） */
    fun openApp(context: Context, name: String): String {
        val n = name.trim()
        if (n.isEmpty()) return "没有说要打开哪个应用"
        val pm = context.packageManager
        val apps = pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .map { it.activityInfo.packageName to it.loadLabel(pm).toString() }
            .distinctBy { it.first }
        val hit = apps.firstOrNull { it.second.equals(n, ignoreCase = true) }
            ?: apps.filter { it.second.contains(n, ignoreCase = true) || n.contains(it.second, ignoreCase = true) && it.second.length >= 2 }.minByOrNull { it.second.length }
            ?: return "没找到叫「$n」的应用"
        val intent = pm.getLaunchIntentForPackage(hit.first) ?: return "「${hit.second}」打不开"
        return if (start(context, intent)) "已打开「${hit.second}」" else "没能打开「${hit.second}」（系统不允许从后台打开，请先点亮屏幕再试）"
    }

    /** [page]：wifi / bluetooth / nfc / hotspot / airplane / display / sound / battery / location / apps / accessibility / date / storage / notifications */
    fun openSettings(context: Context, page: String): String {
        val (action, label) = when (page) {
            "wifi" -> Settings.ACTION_WIFI_SETTINGS to "WLAN 设置"
            "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS to "蓝牙设置"
            "nfc" -> Settings.ACTION_NFC_SETTINGS to "NFC 设置"
            "hotspot" -> "android.settings.TETHER_SETTINGS" to "个人热点设置"
            "airplane" -> Settings.ACTION_AIRPLANE_MODE_SETTINGS to "飞行模式设置"
            "display" -> Settings.ACTION_DISPLAY_SETTINGS to "显示设置"
            "sound" -> Settings.ACTION_SOUND_SETTINGS to "声音设置"
            "battery" -> Settings.ACTION_BATTERY_SAVER_SETTINGS to "省电设置"
            "location" -> Settings.ACTION_LOCATION_SOURCE_SETTINGS to "定位设置"
            "apps" -> Settings.ACTION_APPLICATION_SETTINGS to "应用设置"
            "accessibility" -> Settings.ACTION_ACCESSIBILITY_SETTINGS to "无障碍设置"
            "date" -> Settings.ACTION_DATE_SETTINGS to "日期和时间设置"
            "storage" -> Settings.ACTION_INTERNAL_STORAGE_SETTINGS to "存储设置"
            "notifications" -> Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS to "通知设置"
            else -> return "page 只能是 wifi / bluetooth / nfc / hotspot / airplane / display / sound / battery / location / apps / accessibility / date / storage / notifications"
        }
        return if (start(context, Intent(action))) "已打开$label" else "没能打开$label"
    }

    /** 启动一个界面：优先用无障碍服务（可以从后台启动），不行再用普通 Context；失败返回 false */
    private fun start(context: Context, intent: Intent): Boolean {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val ctx: Context = ExcerptService.instance ?: context
        return try {
            ctx.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        } catch (_: Exception) {
            false
        }
    }
}
