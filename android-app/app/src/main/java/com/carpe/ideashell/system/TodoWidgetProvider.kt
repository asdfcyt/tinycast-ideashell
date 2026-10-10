package com.carpe.ideashell.system

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.os.Bundle
import com.carpe.ideashell.IdeashellApp

/** 桌面待办小部件。内容由 [TodoSurfaces] 渲染；这里只负责系统回调。 */
class TodoWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        val container = (context.applicationContext as IdeashellApp).container
        // 先用缓存立刻画出来，再后台刷新；刷新完成后由状态监听统一重绘
        container.surfaces.updateWidgets(appWidgetIds)
        container.todos.refresh(staleMs = 5 * 60_000L)
    }

    /** 用户拖拽调整大小：重新按新高度决定显示几行 */
    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        val container = (context.applicationContext as IdeashellApp).container
        container.surfaces.updateWidgets(intArrayOf(appWidgetId))
    }

    override fun onEnabled(context: Context) {
        TodoRefreshScheduler.schedule(context)
    }
}
