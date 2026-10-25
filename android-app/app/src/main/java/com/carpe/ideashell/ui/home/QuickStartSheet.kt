package com.carpe.ideashell.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import com.carpe.ideashell.R
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.core.plan.Scheduler
import com.carpe.ideashell.core.plan.cleanTitle
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.llm.QuickStartPlan
import com.carpe.ideashell.ui.components.AppMenu
import com.carpe.ideashell.ui.components.AppMenuItem
import com.carpe.ideashell.ui.glass.GlassButton
import com.carpe.ideashell.ui.glass.GlassOutlinedButton
import com.carpe.ideashell.ui.glass.GlassSheet
import com.carpe.ideashell.ui.glass.GlassSurface
import com.carpe.ideashell.ui.theme.Brand
import java.time.LocalDate

private val GREEN = Color(0xFF3E9A5B)
private val BLUE = Color(0xFF3F7FCB)

/**
 * 快速启动：AI 梳理今天要做的事、值得留意的事，并给一个 10~25 分钟的小目标，点一下就开始专注。
 * @param onStarted 已经开始专注后调用（用来关掉弹层并跳到专注页）
 */
@Composable
fun QuickStartSheet(vm: AiAssistViewModel, onDismiss: () -> Unit, onStarted: () -> Unit) {
    LaunchedEffect(Unit) { vm.openQuickStart() }
    val scheme = MaterialTheme.colorScheme
    val state = vm.quickStart

    fun start(task: DidaTask?, minutes: Int) {
        if (vm.startFocus(task, minutes)) onStarted()
    }

    GlassSheet(onDismiss = onDismiss, topRadius = 32.dp) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.9f)) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(Modifier.size(28.dp).clip(CircleShape).background(Brand.Orange), contentAlignment = Alignment.Center) {
                    Icon(painterResource(R.drawable.ic_bolt), null, tint = Brand.Brown, modifier = Modifier.size(16.dp))
                }
                Column(Modifier.weight(1f)) {
                    Text("快速启动", fontSize = 17.sp, fontWeight = FontWeight.ExtraBold)
                    Text("AI 帮你理一理今天，不用一下子做完", fontSize = 11.sp, color = scheme.onSurfaceVariant)
                }
            }

            Column(
                modifier = Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                when (state) {
                    QuickStartUi.Idle, QuickStartUi.Loading -> Column(
                        Modifier.fillMaxWidth().height(200.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
                    ) {
                        CircularProgressIndicator(strokeWidth = 3.dp, color = Brand.Orange)
                        Text("正在梳理今天的待办、笔记和 Daily Note…", fontSize = 13.sp, color = scheme.onSurfaceVariant)
                    }

                    is QuickStartUi.Error -> GlassSurface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), tint = Brand.Orange) {
                        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(state.text, fontSize = 13.sp, lineHeight = 18.sp)
                            if (!vm.llmConfigured) {
                                Text("到「设置 → 账号与连接」里填写大模型的接口地址、模型名和 Key 后再试。", fontSize = 11.sp, color = scheme.onSurfaceVariant)
                            }
                        }
                    }

                    is QuickStartUi.Ready -> PlanContent(vm, state.plan, ::start)
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val plan = (state as? QuickStartUi.Ready)?.plan
                GlassOutlinedButton(onClick = vm::loadQuickStart, enabled = state !is QuickStartUi.Loading, modifier = Modifier.height(36.dp)) {
                    Icon(Icons.Filled.Refresh, null, Modifier.size(16.dp))
                    Text("  重新梳理", fontSize = 13.sp, fontWeight = FontWeight.Bold)
                }
                Box(Modifier.weight(1f))
                if (plan != null) {
                    GlassButton(onClick = { start(plan.startTask, plan.startMinutes) }, tint = Brand.Orange, contentColor = Brand.Brown, modifier = Modifier.height(36.dp)) {
                        Icon(Icons.Filled.PlayArrow, null, Modifier.size(16.dp))
                        Text("  开始 ${plan.startMinutes} 分钟", fontSize = 13.sp, fontWeight = FontWeight.ExtraBold)
                    }
                }
            }
        }
    }
}

@Composable
private fun PlanContent(vm: AiAssistViewModel, p: QuickStartPlan, start: (DidaTask?, Int) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    if (p.greeting.isNotBlank()) {
        Text(p.greeting, fontSize = 15.sp, lineHeight = 21.sp, fontWeight = FontWeight.Bold)
    }

    Block("今天做这几件", Brand.OrangeDeep) {
        p.focus.forEachIndexed { i, f ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
                Box(Modifier.padding(top = 1.dp).size(18.dp).clip(CircleShape).background(Brand.Orange), contentAlignment = Alignment.Center) {
                    Text("${i + 1}", fontSize = 10.sp, fontWeight = FontWeight.ExtraBold, color = Brand.Brown)
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(f.title, fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Bold)
                    if (f.why.isNotBlank()) Text(f.why, fontSize = 11.sp, lineHeight = 15.sp, color = scheme.onSurfaceVariant)
                }
                if (f.task != null) {
                    Box(
                        Modifier.size(28.dp).clip(CircleShape).background(Brand.Orange).clickable { start(f.task, 25) },
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.Filled.PlayArrow, "专注 25 分钟：" + cleanTitle(f.task.title), tint = Brand.Brown, modifier = Modifier.size(16.dp)) }
                }
            }
        }
    }

    // 无压启动：整张卡点一下就开始
    GlassSurface(
        Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        tint = GREEN,
        onClick = { start(p.startTask, p.startMinutes) },
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("无压启动", fontSize = 11.sp, fontWeight = FontWeight.ExtraBold, color = GREEN)
            Text(p.startTitle, fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.ExtraBold)
            if (p.startStep.isNotBlank()) Text("第一步：" + p.startStep, fontSize = 12.sp, lineHeight = 17.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Pill("${p.startMinutes} 分钟", GREEN)
                p.startTask?.let { Pill("关联：" + cleanTitle(it.title), scheme.onSurfaceVariant) }
            }
            if (p.tip.isNotBlank()) Text(p.tip, fontSize = 11.sp, color = scheme.onSurfaceVariant)
            Box(
                Modifier.fillMaxWidth().height(34.dp).clip(CircleShape).background(GREEN),
                contentAlignment = Alignment.Center,
            ) {
                Text("现在就开始 ${p.startMinutes} 分钟", fontSize = 13.sp, fontWeight = FontWeight.ExtraBold, color = Color.White)
            }
        }
    }

    if (p.watch.isNotEmpty()) {
        Block("留意一下", BLUE) {
            p.watch.forEach { w ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.padding(top = 7.dp).size(4.dp).clip(CircleShape).background(BLUE.copy(alpha = 0.6f)))
                    Text(w, fontSize = 12.sp, lineHeight = 17.sp)
                }
            }
        }
    }

    if (p.later.isNotEmpty()) {
        Block("可以先放一放", scheme.onSurfaceVariant) {
            p.later.forEachIndexed { i, w ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("· " + w.text, fontSize = 12.sp, lineHeight = 17.sp, color = scheme.onSurfaceVariant, modifier = Modifier.weight(1f))
                    if (w.task != null) PostponeControl(vm, "later$i", w.task)
                }
            }
        }
    }
}

/** 「延期」：改到明天 / 后天 / 下周一，保留原来的时间点；改完这一行显示结果 */
@Composable
private fun PostponeControl(vm: AiAssistViewModel, key: String, task: DidaTask) {
    val done = vm.postponed[key]
    if (done != null) {
        Text(done, fontSize = 11.sp, fontWeight = FontWeight.Bold, color = GREEN)
        return
    }
    var open by remember { mutableStateOf(false) }
    Box {
        Text(
            "延期",
            fontSize = 11.sp,
            fontWeight = FontWeight.ExtraBold,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.clip(CircleShape).clickable { open = true }.padding(horizontal = 8.dp, vertical = 4.dp),
        )
        AppMenu(expanded = open, onDismissRequest = { open = false }) {
            val today = LocalDate.now()
            listOf(
                "明天" to today.plusDays(1),
                "后天" to today.plusDays(2),
                "下周一" to Scheduler.nextMonday(today),
            ).forEach { (label, date) ->
                AppMenuItem(text = { Text(label) }, onClick = {
                    open = false
                    vm.postpone(key, task, date, label)
                })
            }
        }
    }
}

@Composable
private fun Block(title: String, color: Color, content: @Composable () -> Unit) {
    GlassSurface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, fontSize = 11.sp, fontWeight = FontWeight.ExtraBold, color = color)
            content()
        }
    }
}

@Composable
private fun Pill(text: String, color: Color) {
    Text(
        text,
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        color = color,
        maxLines = 1,
        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
        modifier = Modifier.clip(CircleShape).background(color.copy(alpha = 0.14f)).padding(horizontal = 8.dp, vertical = 2.dp),
    )
}
