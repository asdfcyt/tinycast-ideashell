package com.carpe.ideashell.ui.focus

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.data.focus.FocusKind
import com.carpe.ideashell.ui.theme.ApplyEdgeToEdge
import com.carpe.ideashell.ui.theme.IdeashellTheme
import com.carpe.ideashell.ui.theme.isDark

/**
 * 专注小部件上点圆环：弹出和专注页一样的可转动圆盘（拖动 / 点选时长）+「专注什么」（可选任务 / 项目），
 * 点「开始」就按所选时长和任务专注。点空白处关闭；不开始就什么都不改，小部件继续显示今天的专注。
 */
class FocusPickActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val container = (application as IdeashellApp).container
        // 已经有一次在进行就不用选了
        if (container.focus.session.value != null) {
            finish()
            return
        }

        setContent {
            val settings by container.settings.state.collectAsStateWithLifecycle()
            val vm: FocusViewModel = viewModel(factory = FocusViewModel.Factory.instance)
            val tasks by vm.tasks.collectAsStateWithLifecycle()
            val projects by vm.projects.collectAsStateWithLifecycle()
            val cycle by vm.cycle.collectAsStateWithLifecycle()
            var pickTask by remember { mutableStateOf(false) }
            IdeashellTheme(settings.themeMode) {
                ApplyEdgeToEdge(isDark(settings.themeMode))
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.40f))
                        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { finish() }
                        .safeDrawingPadding(),
                    contentAlignment = Alignment.Center,
                ) {
                    // 点卡片区域不关闭（里面的点按 / 拖动自己处理）
                    Column(
                        modifier = Modifier
                            .verticalScroll(rememberScrollState())
                            .padding(20.dp)
                            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        TimerCard(
                            run = null,
                            now = System.currentTimeMillis(),
                            kind = FocusKind.FOCUS,
                            cycle = cycle,
                            minutes = vm.minutes,
                            onSkipBreak = {},
                            onMinutes = { vm.minutes = it },
                            onStart = {
                                vm.start()
                                container.widgets.updateFocus()
                                finish()
                            },
                        )
                        TaskRow(run = null, task = vm.task, project = vm.project, onClick = { pickTask = true })
                    }
                }
                if (pickTask) {
                    TaskPicker(
                        tasks = tasks,
                        projects = projects,
                        selected = vm.task?.id,
                        selectedProject = vm.project,
                        projectOf = vm::projectOf,
                        adding = vm.adding,
                        onAdd = { title -> vm.addTask(title) { pickTask = false } },
                        onSelect = { t, p ->
                            vm.choose(t, p)
                            pickTask = false
                        },
                        onDismiss = { pickTask = false },
                    )
                }
            }
        }
    }

    override fun finish() {
        super.finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
