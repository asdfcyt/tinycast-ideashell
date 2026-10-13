package com.carpe.ideashell.system

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.ui.MainActivity

/** 快速设置磁贴「专注」：下拉通知栏点一下，直接打开专注页（专注中时磁贴是点亮的） */
class FocusTileService : TileService() {

    override fun onStartListening() {
        val run = (application as IdeashellApp).container.focus.session.value
        qsTile?.apply {
            state = if (run != null) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            label = run?.kind?.label?.let { if (run.paused) "${it}已暂停" else "${it}中" } ?: "专注"
            updateTile()
        }
    }

    override fun onClick() {
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(MainActivity.EXTRA_OPEN_FOCUS, true)
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
