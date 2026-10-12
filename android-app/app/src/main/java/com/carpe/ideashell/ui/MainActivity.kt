package com.carpe.ideashell.ui

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.R
import com.carpe.ideashell.ui.diagnostics.DiagnosticsScreen
import com.carpe.ideashell.ui.glass.AddFab
import com.carpe.ideashell.ui.glass.AppNavBar
import com.carpe.ideashell.ui.glass.AuroraBackground
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import com.carpe.ideashell.ui.glass.NavBarGap
import com.carpe.ideashell.ui.glass.NavBarHeight
import com.carpe.ideashell.ui.capture.QuickCaptureActivity
import androidx.compose.ui.platform.LocalContext
import com.carpe.ideashell.ui.glass.NavItem
import com.carpe.ideashell.ui.home.HomeScreen
import com.carpe.ideashell.ui.review.NoteDetailScreen
import com.carpe.ideashell.ui.review.ReviewScreen
import com.carpe.ideashell.ui.search.SearchScreen
import com.carpe.ideashell.ui.search.SearchViewModel
import com.carpe.ideashell.ui.settings.SettingsScreen
import com.carpe.ideashell.ui.theme.ApplyEdgeToEdge
import com.carpe.ideashell.ui.theme.IdeashellTheme
import com.carpe.ideashell.ui.theme.isDark
import com.carpe.ideashell.ui.todos.TodoScreen
import com.carpe.ideashell.ui.todos.TodoViewModel

private const val PAGE_TABS = 0
private const val PAGE_CONNECTION = 1
private const val PAGE_NOTE = 2
private const val PAGE_SEARCH = 3
private const val TAB_HOME = 0
private const val TAB_TODOS = 1
private const val TAB_REVIEW = 2
private const val TAB_SETTINGS = 3

private val NAV_ITEMS = listOf(
    NavItem("今天", R.drawable.ic_nav_today),
    NavItem("待办", R.drawable.ic_nav_todo),
    NavItem("回看", R.drawable.ic_nav_review),
    NavItem("设置", R.drawable.ic_nav_settings),
)

class MainActivity : ComponentActivity() {
    /** 小部件 / 通知点进来时指定要打开的页签；界面消费后清空 */
    private var requestedTab by mutableStateOf<Int?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val container = (application as IdeashellApp).container
        requestedTab = readTab(intent)

        setContent {
            val settings by container.settings.state.collectAsStateWithLifecycle()
            IdeashellTheme(settings.themeMode) {
                ApplyEdgeToEdge(isDark(settings.themeMode))
                AppRoot(requestedTab = requestedTab, onTabConsumed = { requestedTab = null })
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        requestedTab = readTab(intent)
    }

    private fun readTab(intent: Intent?): Int? =
        intent?.getIntExtra(EXTRA_TAB, -1)?.takeIf { it in TAB_HOME..TAB_SETTINGS }

    companion object {
        const val EXTRA_TAB = "tab"
    }
}

/**
 * 根布局：纯色背景 + 当前页面 + 底部导航。
 * 四个主页签（今天 / 待办 / 回看 / 设置）；「搜索」「连接与诊断」「笔记全文」作为子页面盖在上面，此时隐藏导航栏。
 * 搜索入口在各页面标题栏的右侧。
 *
 * 切页签不做任何转场动画：同时存在两个整页的组合 + 缩放 / 渐隐，是之前卡顿的主要来源。
 * 页签之间直接切换，每个页签的滚动位置等界面状态由 [rememberSaveableStateHolder] 保存；
 * 数据本来就在各自的 ViewModel 里，回来时先显示已有内容。只有进入 / 退出子页面才有横向滑入动画。
 */
@Composable
private fun AppRoot(requestedTab: Int?, onTabConsumed: () -> Unit) {
    var tab by rememberSaveable { mutableIntStateOf(requestedTab ?: TAB_HOME) }
    var connection by rememberSaveable { mutableStateOf(false) }
    var search by rememberSaveable { mutableStateOf(false) }
    var noteId by rememberSaveable { mutableStateOf<String?>(null) }
    // 退出动画期间 noteId 已经是 null，但旧页面还要再画一会儿，所以留一份最后打开的 id
    val lastNoteId = remember { arrayOf<String?>(null) }
    if (noteId != null) lastNoteId[0] = noteId
    // 搜索页的 ViewModel 提升到这里：笔记里点非项目标签时，要从外面直接发起一次搜索
    val searchVm: SearchViewModel = viewModel(factory = SearchViewModel.Factory)
    val todo: TodoViewModel = viewModel(factory = TodoViewModel.Factory)
    val subpage = connection || search || noteId != null
    val stateHolder = rememberSaveableStateHolder()

    LaunchedEffect(requestedTab) {
        if (requestedTab != null) {
            tab = requestedTab
            connection = false
            search = false
            noteId = null
            onTabConsumed()
        }
    }

    BackHandler(enabled = subpage || tab != TAB_HOME) {
        when {
            noteId != null -> noteId = null
            connection -> connection = false
            search -> search = false
            else -> tab = TAB_HOME
        }
    }

    val systemNav = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    // 导航胶囊和右侧的「+」在同一行，列表只需要避开这一行
    val bottomPadding = if (subpage) systemNav + 16.dp else systemNav + NavBarHeight + NavBarGap + 12.dp
    val context = LocalContext.current

    Box(Modifier.fillMaxSize()) {
        AuroraBackground()
        CompositionLocalProvider(LocalBottomBarPadding provides bottomPadding) {
            AnimatedContent(
                targetState = when {
                    noteId != null -> PAGE_NOTE
                    connection -> PAGE_CONNECTION
                    search -> PAGE_SEARCH
                    else -> PAGE_TABS
                },
                transitionSpec = {
                    if (targetState != PAGE_TABS) {
                        (slideInHorizontally(tween(260)) { it / 4 } + fadeIn(tween(220))) togetherWith fadeOut(tween(120))
                    } else {
                        fadeIn(tween(200)) togetherWith (slideOutHorizontally(tween(220)) { it / 4 } + fadeOut(tween(160)))
                    }
                },
                label = "page",
            ) { page ->
                when (page) {
                    PAGE_CONNECTION -> DiagnosticsScreen(onBack = { connection = false })
                    PAGE_SEARCH -> SearchScreen(
                        viewModel = searchVm,
                        onBack = { search = false },
                        onOpenConnection = { connection = true },
                        onOpenNote = { noteId = it },
                        onOpenProject = { keyword ->
                            search = false
                            todo.openProject = keyword
                            tab = TAB_TODOS
                        },
                        onOpenTask = { id ->
                            search = false
                            todo.pendingTask = id
                            tab = TAB_TODOS
                        },
                    )
                    PAGE_NOTE -> NoteDetailScreen(
                        noteId = lastNoteId[0].orEmpty(),
                        onBack = { noteId = null },
                        onOpenTag = { tag ->
                            // 标签是项目 → 进项目页；不是 → 打开搜索并直接搜这个词（可展开「提及概览」）
                            val project = searchVm.workspace.value.projects
                                .firstOrNull { it.keyword.equals(tag, ignoreCase = true) }
                            noteId = null
                            if (project != null) {
                                search = false
                                todo.openProject = project.keyword
                                tab = TAB_TODOS
                            } else {
                                search = true
                                searchVm.submit(tag)
                            }
                        },
                    )

                    else -> stateHolder.SaveableStateProvider(tab) {
                        when (tab) {
                            TAB_REVIEW -> ReviewScreen(
                                onOpenSearch = { search = true },
                                onOpenConnection = { connection = true },
                                onOpenNote = { noteId = it },
                                onOpenProject = { keyword ->
                                    todo.openProject = keyword
                                    tab = TAB_TODOS
                                },
                            )

                            TAB_TODOS -> TodoScreen(
                                onOpenSearch = { search = true },
                                onOpenConnection = { connection = true },
                                onOpenNote = { noteId = it },
                            )

                            TAB_SETTINGS -> SettingsScreen(onOpenConnection = { connection = true })
                            else -> HomeScreen(
                                onOpenSearch = { search = true },
                                onOpenConnection = { connection = true },
                                onOpenTodos = { tab = TAB_TODOS },
                                onOpenNote = { noteId = it },
                            )
                        }
                    }
                }
            }
        }

        AnimatedVisibility(
            visible = !subpage,
            modifier = Modifier.align(Alignment.BottomCenter),
            enter = slideInVertically(tween(240)) { it } + fadeIn(tween(200)),
            exit = slideOutVertically(tween(180)) { it } + fadeOut(tween(140)),
        ) {
            AppNavBar(
                items = NAV_ITEMS,
                selected = tab,
                onSelect = { tab = it },
                fab = {
                    AddFab(
                        onClick = {
                            context.startActivity(
                                Intent(context, QuickCaptureActivity::class.java).apply {
                                    action = QuickCaptureActivity.ACTION_QUICK_CAPTURE
                                    // 不预设类型：由输入内容自动判断，也可以在面板上方手动指定
                                },
                            )
                        },
                    )
                },
            )
        }
    }
}
