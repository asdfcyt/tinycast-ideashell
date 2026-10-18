package com.carpe.ideashell.system

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.carpe.ideashell.ui.capture.QuickCaptureActivity

/** 快速设置磁贴「语音记一条」：点一下打开快记面板并直接开始录音，说完点「完成」 */
class VoiceCaptureTileService : TileService() {

    override fun onStartListening() {
        qsTile?.apply {
            state = Tile.STATE_INACTIVE
            updateTile()
        }
    }

    override fun onClick() {
        val intent = Intent(this, QuickCaptureActivity::class.java).apply {
            action = QuickCaptureActivity.ACTION_QUICK_CAPTURE
            putExtra(QuickCaptureActivity.EXTRA_START_VOICE, true)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        if (Build.VERSION.SDK_INT >= 34) {
            val pending = PendingIntent.getActivity(
                this, 1, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
