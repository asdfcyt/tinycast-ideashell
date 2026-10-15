package com.carpe.ideashell.system

import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.carpe.ideashell.IdeashellApp

/** 快速设置磁贴「摘录」：下拉通知栏点一下，开始 / 结束快速摘录模式（开启时磁贴点亮） */
class ExcerptTileService : TileService() {

    override fun onStartListening() = refresh()

    override fun onClick() {
        ExcerptService.toggle(this)
        refresh()
    }

    private fun refresh() {
        val on = (application as IdeashellApp).container.settings.current.excerptMode
        qsTile?.apply {
            state = if (on) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            label = if (on) "摘录中" else "摘录"
            updateTile()
        }
    }
}
