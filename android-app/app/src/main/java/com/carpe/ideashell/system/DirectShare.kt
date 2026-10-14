package com.carpe.ideashell.system

import android.content.Context
import android.content.Intent
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.carpe.ideashell.R
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.data.project.ProjectStatus
import com.carpe.ideashell.data.project.Workspace
import com.carpe.ideashell.ui.capture.QuickCaptureActivity

/**
 * 系统分享菜单第一行的「直接分享」目标（Direct Share）：
 * 拾忆 · 待办 / 日记 / 笔记，以及最多几个进行中的项目（拾忆 · 项目名）——选中后分享的内容直接按这个去向进入输入面板。
 *
 * 做法：用动态快捷方式（带 [CATEGORY]）+ `res/xml/shortcuts.xml` 里的 share-target 声明。
 * 同一批快捷方式也会出现在长按桌面图标的菜单里（点它们等于「记一条 / 记到某个项目」）。
 * 选中后系统启动分享入口，并在 Intent 里带上 [Intent.EXTRA_SHORTCUT_ID]，由 [QuickCaptureActivity] 解析。
 */
object DirectShare {
    /** 必须和 shortcuts.xml 里 share-target 的 category 一致 */
    const val CATEGORY = "com.carpe.ideashell.category.SHARE_TARGET"

    const val ID_TODO = "share_todo"
    const val ID_DAILY = "share_daily"
    const val ID_NOTE = "share_note"
    private const val ID_PROJECT_PREFIX = "share_project:"

    /** 桌面快捷方式带进来的预填文字（项目：「#关键词 」） */
    const val EXTRA_PRESET_TEXT = "preset_text"

    private const val MAX_PROJECTS = 4

    /** 解析出来的去向：类型 + 可选的项目关键词 */
    data class Target(val kind: CaptureKind, val project: String? = null)

    fun parse(shortcutId: String?): Target? = when {
        shortcutId == null -> null
        shortcutId == ID_TODO -> Target(CaptureKind.TODO)
        shortcutId == ID_DAILY -> Target(CaptureKind.DAILY)
        shortcutId == ID_NOTE -> Target(CaptureKind.NOTE)
        shortcutId.startsWith(ID_PROJECT_PREFIX) ->
            shortcutId.removePrefix(ID_PROJECT_PREFIX).takeIf { it.isNotBlank() }?.let { Target(CaptureKind.NOTE, it) }
        else -> null
    }

    /** 要展示的项目：搁置的不要，进行中 > 短期 > 长期，同状态里新建的在前 */
    fun projectKeywords(workspace: Workspace): List<String> =
        workspace.projects
            .filter { it.status != ProjectStatus.PAUSED }
            .sortedWith(compareBy({ it.status.ordinal }, { -it.addedAt }))
            .map { it.keyword.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
            .take(MAX_PROJECTS)

    /** 重新发布全部动态快捷方式（会整体替换旧的）。系统限流、用户未解锁等情况直接忽略，下次项目变化会再来 */
    fun publish(context: Context, projects: List<String>) {
        runCatching {
            val room = ShortcutManagerCompat.getMaxShortcutCountPerActivity(context)
            val shortcuts = buildList {
                add(fixed(context, ID_TODO, "拾忆 · 待办", R.drawable.ic_shortcut_todo, CaptureKind.TODO, null))
                add(fixed(context, ID_DAILY, "拾忆 · 日记", R.drawable.ic_shortcut_note, CaptureKind.DAILY, null))
                add(fixed(context, ID_NOTE, "拾忆 · 笔记", R.drawable.ic_shortcut_note, CaptureKind.NOTE, null))
                projects.forEach { kw ->
                    add(fixed(context, ID_PROJECT_PREFIX + kw, "拾忆 · $kw", R.drawable.ic_shortcut_focus, CaptureKind.NOTE, kw))
                }
            }.take(room.coerceAtLeast(1))
            ShortcutManagerCompat.setDynamicShortcuts(context, shortcuts)
        }
    }

    private fun fixed(
        context: Context,
        id: String,
        label: String,
        icon: Int,
        kind: CaptureKind,
        project: String?,
    ): ShortcutInfoCompat {
        val launch = Intent(context, QuickCaptureActivity::class.java).apply {
            action = QuickCaptureActivity.ACTION_QUICK_CAPTURE
            putExtra(QuickCaptureActivity.EXTRA_KIND, kind.name)
            if (project != null) putExtra(EXTRA_PRESET_TEXT, "#$project ")
        }
        return ShortcutInfoCompat.Builder(context, id)
            .setShortLabel(label)
            .setLongLabel(label)
            .setIcon(IconCompat.createWithResource(context, icon))
            .setIntent(launch)
            .setCategories(setOf(CATEGORY))
            .setLongLived(true)
            .build()
    }
}
