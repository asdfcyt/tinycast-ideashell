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
import androidx.compose.animation.scaleIn
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.ui.diagnostics.DiagnosticsScreen
import com.carpe.ideashell.ui.glass.AuroraBackground
import com.carpe.ideashell.ui.glass.GlassNavBar
import com.carpe.ideashell.ui.glass.GlassNavItem
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import com.carpe.ideashell.ui.home.HomeScreen
import com.carpe.ideashell.ui.review.NoteDetailScreen
import com.carpe.ideashell.ui.review.ReviewScreen
import com.carpe.ideashell.ui.review.ReviewViewModel
import com.carpe.ideashell.ui.search.SearchScreen
import com.carpe.ideashell.ui.settings.SettingsScreen
import com.carpe.ideashell.ui.theme.ApplyEdgeToEdge
import com.carpe.ideashell.ui.theme.IdeashellTheme
import com.carpe.ideashell.ui.theme.isDark
import com.carpe.ideashell.ui.todos.TodoScreen
import com.carpe.ideashell.ui.todos.TodoViewModel
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource

private const val PAGE_CONNECTION = -1
private const val PAGE_NOTE = -2
private const val TAB_HOME = 0
private const val TAB_TODOS = 1
private const val TAB_SEARCH = 2
private const val TAB_REVIEW = 3
private const val TAB_SETTINGS = 4

private val NAV_ITEMS = listOf(
    GlassNavItem("记录", Icons.Filled.Create),
    GlassNavItem("待办", Icons.Filled.CheckCircle),
    GlassNavItem("搜索", Icons.Filled.Search),
    GlassNavItem("回看", Icons.Filled.DateRange),
    GlassNavItem("设置", Icons.Filled.Settings),
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
 * 根布局：彩色光晕背景 + 当前页面（同属一个 Haze 背景源）+ 底部悬浮玻璃导航。
 * 五个主页签（记录 / 待办 / 搜索 / 回看 / 设置）；「连接与诊断」与「笔记全文」作为子页面盖在上面，此时隐藏导航栏。
 */
@Composable
private fun AppRoot(requestedTab: Int?, onTabConsumed: () -> Unit) {
    var tab by rememberSaveable { mutableIntStateOf(requestedTab ?: TAB_HOME) }
    var connection by rememberSaveable { mutableStateOf(false) }
    var noteId by rememberSaveable { mutableStateOf<String?>(null) }
    // 退出动画期间 noteId 已经是 null，但旧页面还要再画一会儿，所以留一份最后打开的 id
    val lastNoteId = remember { arrayOf<String?>(null) }
    if (noteId != null) lastNoteId[0] = noteId
    val review: ReviewViewModel = viewModel(factory = ReviewViewModel.Factory)
    val todo: TodoViewModel = viewModel(factory = TodoViewModel.Factory)
    val subpage = connection || noteId != null
    val haze = remember { HazeState() }

    LaunchedEffect(requestedTab) {
        if (requestedTab != null) {
            tab = requestedTab
            connection = false
            noteId = null
            onTabConsumed()
        }
    }

    BackHandler(enabled = subpage || tab != TAB_HOME) {
        when {
            noteId != null -> noteId = null
            connection -> connection = false
            else -> tab = TAB_HOME
        }
    }

    val systemNav = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    // 导航栏本体高度 66 + 上下外边距 28，再留一点呼吸空间
    val bottomPadding = if (subpage) systemNav + 16.dp else systemNav + 66.dp + 28.dp + 12.dp

    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().hazeSource(haze)) {
            AuroraBackground()
            CompositionLocalProvider(LocalBottomBarPadding provides bottomPadding) {
                AnimatedContent(
                    targetState = if (noteId != null) PAGE_NOTE else if (connection) PAGE_CONNECTION else tab,
                    transitionSpec = {
                        when {
                            targetState < 0 ->
                                (slideInHorizontally(tween(300)) { it / 4 } + fadeIn(tween(260))) togetherWith fadeOut(tween(160))

                            initialState < 0 ->
                                fadeIn(tween(260)) togetherWith (slideOutHorizontally(tween(260)) { it / 4 } + fadeOut(tween(200)))

                            else ->
                                (fadeIn(tween(240)) + scaleIn(tween(240), initialScale = 0.97f)) togetherWith fadeOut(tween(120))
                        }
                    },
                    label = "page",
                ) { page ->
                    when (page) {
                        PAGE_CONNECTION -> DiagnosticsScreen(onBack = { connection = false })
                        PAGE_NOTE -> NoteDetailScreen(
                            noteId = lastNoteId[0].orEmpty(),
                            onBack = { noteId = null },
                            onOpenDossier = { keyword ->
                                noteId = null
                                tab = TAB_REVIEW
                                review.jumpToDossier(keyword)
                            },
                        )
                        TAB_REVIEW -> ReviewScreen(
                            onOpenConnection = { connection = true },
                            onOpenNote = { noteId = it },
                        )
                        TAB_TODOS -> TodoScreen(
                            onOpenConnection = { connection = true },
                            onOpenNote = { noteId = it },
                            onOpenDossier = { keyword ->
                                tab = TAB_REVIEW
                                review.jumpToDossier(keyword)
                            },
                        )
                        TAB_SEARCH -> SearchScreen(
                            onOpenConnection = { connection = true },
                            onOpenNote = { noteId = it },
                            onOpenDossier = { keyword ->
                                tab = TAB_REVIEW
                                review.jumpToDossier(keyword)
                            },
                            onOpenProject = { keyword ->
                                todo.openProject = keyword
                                tab = TAB_TODOS
                            },
                            onOpenTask = { id ->
                                todo.pendingTask = id
                                tab = TAB_TODOS
                            },
                        )
                        TAB_SETTINGS -> SettingsScreen(onOpenConnection = { connection = true })
                        else -> HomeScreen(onOpenConnection = { connection = true })
                    }
                }
            }
        }

        AnimatedVisibility(
            visible = !subpage,
            modifier = Modifier.align(Alignment.BottomCenter),
            enter = slideInVertically(tween(300)) { it } + fadeIn(tween(240)),
            exit = slideOutVertically(tween(200)) { it } + fadeOut(tween(160)),
        ) {
            GlassNavBar(
                items = NAV_ITEMS,
                selected = tab,
                onSelect = { tab = it },
                hazeState = haze,
            )
        }
    }
}
