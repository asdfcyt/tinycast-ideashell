package com.carpe.ideashell.system

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.ContextCompat
import com.carpe.ideashell.ui.capture.QuickCaptureActivity

/**
 * 「语音记一条」的透明跳板：磁贴和桌面快捷方式都先到这里。
 * 麦克风权限和「显示在其他应用上层」都有，就直接开悬浮录音胶囊（正在录就是「完成」）；
 * 缺任何一个权限，退回打开快记面板里录音（面板会自己申请麦克风权限），并提示怎么打开悬浮胶囊。
 */
class VoiceCapsuleActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val hasMic = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val canOverlay = Settings.canDrawOverlays(this)
        if (hasMic && canOverlay) {
            VoiceCapsuleService.toggle(this)
        } else {
            if (hasMic && !canOverlay) {
                Toast.makeText(this, "在「设置 → 语音输入」里开启「悬浮胶囊」权限，就能不打开面板直接录音", Toast.LENGTH_LONG).show()
            }
            startActivity(
                Intent(this, QuickCaptureActivity::class.java).apply {
                    action = QuickCaptureActivity.ACTION_QUICK_CAPTURE
                    putExtra(QuickCaptureActivity.EXTRA_START_VOICE, true)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                },
            )
        }
        finish()
    }
}
