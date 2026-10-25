package com.carpe.ideashell.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.R
import com.carpe.ideashell.core.plan.cleanTitle
import com.carpe.ideashell.core.plan.parseDay
import com.carpe.ideashell.data.llm.AiMove
import com.carpe.ideashell.data.llm.AiNewTask
import com.carpe.ideashell.data.llm.DraftItem
import com.carpe.ideashell.ui.glass.GlassButton
import com.carpe.ideashell.ui.glass.GlassOutlinedButton
import com.carpe.ideashell.ui.glass.GlassSheet
import com.carpe.ideashell.ui.glass.GlassSurface
import com.carpe.ideashell.ui.theme.Brand
import java.time.LocalDate
import java.time.temporal.ChronoUnit
import java.util.Locale

private val PURPLE = Color(0xFF5A6B80) // 石板灰蓝（沿用旧名，避免大面积改动）
private val RED = Color(0xFFD64545)
private val GREEN = Color(0xFF3E9A5B)

/**
 * AI 规划，两步走：
 * ① 拆解并分配时间：把脑子里还没记下来的事倒出来，AI 拆成具体小任务并估好每个要多久（时长可调）；
 * ② 排期：根据今天已有的任务（带时间的、日历事件占着的时段），把拆好的小任务排进空档，并处理逾期 / 未排期的待办。
 * 每一项都能取消勾选，点「应用」才写进滴答。带时间的任务占用「预计时长」，方案里不会让两件事的时段重叠。
 */
@Composable
fun ReplanSheet(vm: AiAssistViewModel, onDismiss: () -> Unit) {
    LaunchedEffect(Unit) { vm.openPlan() }
    val scheme = MaterialTheme.colorScheme
    val ui = vm.planUi

    GlassSheet(onDismiss = onDismiss, topRadius = 32.dp) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.92f)) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(Modifier.size(28.dp).clip(CircleShape).background(MaterialTheme.colorScheme.onSurface), contentAlignment = Alignment.Center) {
                    Icon(painterResource(R.drawable.ic_sparkle), null, tint = MaterialTheme.colorScheme.surface, modifier = Modifier.size(16.dp))
                }
                Column(Modifier.weight(1f)) {
                    Text("AI 规划", fontSize = 17.sp, fontWeight = FontWeight.ExtraBold)
                    Text(
                        when (ui) {
                            is PlanUi.Input -> "先把想做的事倒出来，关掉再打开会接着写"
                            is PlanUi.Breakdown -> "核对一下任务和时长，没问题再去排期"
                            is PlanUi.Result -> "确认前不会改动，每一项都可以取消勾选"
                            is PlanUi.Failed -> "出错了"
                            else -> "AI 分析中，可以先关掉，回来接着看"
                        },
                        fontSize = 11.sp,
                        color = scheme.onSurfaceVariant,
                    )
                }
                // 想丢掉上一轮重来：输入 / 拆解 / 计划都清掉
                if (ui is PlanUi.Breakdown || ui is PlanUi.Result || (ui is PlanUi.Input && vm.goals.isNotBlank())) {
                    Text(
                        "重新开始",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color = scheme.primary,
                        modifier = Modifier.clip(CircleShape).clickable(onClick = vm::restartPlan).padding(horizontal = 10.dp, vertical = 6.dp),
                    )
                }
            }

            if (ui !is PlanUi.Idle && !(ui is PlanUi.Failed && vm.planStep == 0)) StepBar(vm.planStep)

            Column(Modifier.weight(1f).fillMaxWidth()) {
                when (ui) {
                    PlanUi.Idle -> Unit
                    is PlanUi.Loading -> Column(
                        Modifier.fillMaxSize2(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
                    ) {
                        CircularProgressIndicator(strokeWidth = 3.dp, color = Brand.Orange)
                        Text(
                            ui.text,
                            fontSize = 13.sp,
                            lineHeight = 18.sp,
                            color = scheme.onSurfaceVariant,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                            modifier = Modifier.padding(horizontal = 32.dp),
                        )
                    }

                    is PlanUi.Failed -> Column(Modifier.padding(16.dp)) {
                        NoteCard(Brand.Orange) { Text(ui.text, fontSize = 13.sp, lineHeight = 18.sp) }
                    }

                    PlanUi.Input -> InputContent(vm)
                    is PlanUi.Breakdown -> BreakdownContent(vm, ui)
                    is PlanUi.Result -> ResultContent(vm, ui)
                }
            }

            HorizontalDivider(thickness = 0.5.dp, color = scheme.outlineVariant)
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                when (ui) {
                    PlanUi.Input -> {
                        GlassOutlinedButton(onClick = vm::skipToSchedule, modifier = Modifier.height(36.dp)) {
                            Text("没有新事，直接排期", fontSize = 13.sp, fontWeight = FontWeight.Bold)
                        }
                        Box(Modifier.weight(1f))
                        GlassButton(
                            onClick = vm::decompose,
                            enabled = vm.goals.isNotBlank(),
                            tint = Brand.Orange,
                            contentColor = Brand.Brown,
                            modifier = Modifier.height(36.dp),
                        ) { Text("拆解并分配时间", fontSize = 13.sp, fontWeight = FontWeight.ExtraBold) }
                    }

                    is PlanUi.Breakdown -> {
                        val n = vm.checkedDraft.size
                        GlassOutlinedButton(onClick = vm::backToInput, modifier = Modifier.height(36.dp)) {
                            Text("重新输入", fontSize = 13.sp, fontWeight = FontWeight.Bold)
                        }
                        Box(Modifier.weight(1f))
                        GlassButton(
                            onClick = vm::schedule,
                            enabled = n > 0,
                            tint = Brand.Orange,
                            contentColor = Brand.Brown,
                            modifier = Modifier.height(36.dp),
                        ) { Text(if (n == 0) "下一步：排期" else "下一步：排期（$n 项）", fontSize = 13.sp, fontWeight = FontWeight.ExtraBold) }
                    }

                    is PlanUi.Result -> {
                        val count = vm.checkedMoves.size + vm.checkedNew.size
                        GlassOutlinedButton(onClick = vm::backToBreakdown, modifier = Modifier.height(36.dp)) {
                            Text("调整任务", fontSize = 13.sp, fontWeight = FontWeight.Bold)
                        }
                        Box(Modifier.weight(1f))
                        GlassButton(
                            onClick = { vm.applyPlan(onDismiss) },
                            enabled = count > 0 && !vm.applying,
                            tint = Brand.Orange,
                            contentColor = Brand.Brown,
                            modifier = Modifier.height(36.dp),
                        ) {
                            if (vm.applying) {
                                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = Brand.Brown)
                            } else {
                                Text(if (count == 0) "应用" else "应用（$count 项）", fontSize = 13.sp, fontWeight = FontWeight.ExtraBold)
                            }
                        }
                    }

                    is PlanUi.Failed -> {
                        Box(Modifier.weight(1f))
                        GlassButton(onClick = vm::retryPlan, tint = Brand.Orange, contentColor = Brand.Brown, modifier = Modifier.height(36.dp)) {
                            Text("重试", fontSize = 13.sp, fontWeight = FontWeight.ExtraBold)
                        }
                    }

                    else -> Box(Modifier.height(36.dp))
                }
            }
        }
    }
}

private fun Modifier.fillMaxSize2(): Modifier = this.fillMaxWidth().fillMaxHeight()

// ───────────────────────── 步骤条 ─────────────────────────

@Composable
private fun StepBar(step: Int) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        StepPill(1, "拆解并分配时间", on = step == 1, done = step > 1)
        Text("›", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        StepPill(2, "根据今天已有任务排期", on = step == 2, done = false)
    }
}

@Composable
private fun StepPill(n: Int, text: String, on: Boolean, done: Boolean) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(if (on) Brand.Orange else scheme.onSurface.copy(alpha = 0.07f))
            .padding(start = 3.dp, end = 9.dp, top = 3.dp, bottom = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Box(
            Modifier.size(16.dp).clip(CircleShape).background(if (on) Brand.Brown.copy(alpha = 0.18f) else scheme.onSurface.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center,
        ) {
            if (done) {
                Icon(Icons.Filled.Check, null, tint = scheme.onSurfaceVariant, modifier = Modifier.size(11.dp))
            } else {
                Text("$n", fontSize = 10.sp, fontWeight = FontWeight.ExtraBold, color = if (on) Brand.Brown else scheme.onSurfaceVariant)
            }
        }
        Text(
            text,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = if (on) Brand.Brown else scheme.onSurfaceVariant,
            maxLines = 1,
        )
    }
}

// ───────────────────────── 第一步：输入 ─────────────────────────

@Composable
private fun InputContent(vm: AiAssistViewModel) {
    val scheme = MaterialTheme.colorScheme
    Column(
        modifier = Modifier.fillMaxSize2().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Block {
            StageTag("第一步", Color(0xFF3F7FCB))
            Text("今天想做什么、什么时候有空 / 没空？", fontSize = 14.sp, lineHeight = 19.sp, fontWeight = FontWeight.ExtraBold)
            Text(
                "想到什么写什么，不用整理。AI 会先认出里面哪些是你已有的待办（比如「看书」就是已有的「阅读」，不会重复新建）、哪些是新事，估好时长、记下你说的时间限制；再根据今天已有的任务排期。",
                fontSize = 11.sp,
                lineHeight = 15.sp,
                color = scheme.onSurfaceVariant,
            )
            Field(vm.goals, onChange = { vm.goals = it }, hint = "比如：下午要出去吃饭，晚上才有时间看书；另外还要取快递、给妈妈打电话、把周报写完……", minHeight = 160.dp)
        }
        Text(
            "没有新的事要加？点左下角「没有新事，直接排期」，只把逾期 / 没排期的待办重新排一遍。",
            fontSize = 11.sp,
            lineHeight = 15.sp,
            color = scheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 4.dp),
        )
    }
}

// ───────────────────────── 第一步：拆解结果 ─────────────────────────

@Composable
private fun BreakdownContent(vm: AiAssistViewModel, ui: PlanUi.Breakdown) {
    val scheme = MaterialTheme.colorScheme
    val chosen = vm.draft.filter { it.key in vm.checkedDraft }
    val total = chosen.sumOf { it.minutes }
    Column(
        modifier = Modifier.fillMaxSize2().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (ui.note.isNotBlank()) Text(ui.note, fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Bold)

        val existing = vm.draft.filter { it.taskId != null }
        val fresh = vm.draft.filter { it.taskId == null }
        if (existing.isNotEmpty()) {
            Block {
                BlockTitle("已有待办 ${existing.count { it.key in vm.checkedDraft }}/${existing.size} · 不会重复新建，只重新定时间", Color(0xFF3F7FCB))
                existing.forEachIndexed { i, d ->
                    if (i > 0) HorizontalDivider(thickness = 0.5.dp, color = scheme.outlineVariant)
                    DraftRow(d, checked = d.key in vm.checkedDraft, onToggle = { vm.toggleDraft(d.key) }, onMinus = {}, onPlus = {})
                }
            }
        }
        if (fresh.isNotEmpty()) {
            Block {
                BlockTitle("新事 ${fresh.count { it.key in vm.checkedDraft }}/${fresh.size} · 排期时新建任务", GREEN)
                fresh.forEachIndexed { i, d ->
                    if (i > 0) HorizontalDivider(thickness = 0.5.dp, color = scheme.outlineVariant)
                    DraftRow(
                        d,
                        checked = d.key in vm.checkedDraft,
                        onToggle = { vm.toggleDraft(d.key) },
                        onMinus = { vm.adjustMinutes(d.key, if (d.minutes <= 30) -5 else -15) },
                        onPlus = { vm.adjustMinutes(d.key, if (d.minutes < 30) 5 else 15) },
                    )
                }
            }
        }
        Text("共约 ${spanText(total)}", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = scheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 4.dp))
        Text(
            "不要的取消勾选；新事的时长不准用 − / + 调；已有待办的时长按它自己的预计时长。确认后点「下一步」，AI 会避开今天已有的任务排期。",
            fontSize = 11.sp,
            lineHeight = 15.sp,
            color = scheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 4.dp),
        )
    }
}

@Composable
private fun DraftRow(d: DraftItem, checked: Boolean, onToggle: () -> Unit, onMinus: () -> Unit, onPlus: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val isExisting = d.taskId != null
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
        CheckBox(checked, onToggle)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(d.title, fontSize = 13.sp, lineHeight = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            FlowRowTags {
                d.current?.let { Tag("现在：$it", scheme.onSurfaceVariant) }
                val window = when {
                    d.from != null && d.to != null -> "${d.from}–${d.to}"
                    d.from != null -> "${d.from} 以后"
                    d.to != null -> "${d.to} 之前"
                    else -> null
                }
                window?.let { Tag((if (isExisting) "改到 " else "限定 ") + it, Brand.OrangeDeep) }
                if (d.priority > 0) Tag(listOf("", "低", "", "中", "", "高")[d.priority] + "优先级", if (d.priority >= 5) RED else Brand.OrangeDeep)
                if (d.later) Tag("建议放到之后", scheme.onSurfaceVariant)
                d.project?.let { Tag("#$it", Color(0xFF3F7FCB)) }
            }
            d.parent?.let { Text("来自：$it", fontSize = 11.sp, color = scheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            if (d.reason.isNotBlank()) Text(d.reason, fontSize = 11.sp, lineHeight = 15.sp, color = PURPLE)
        }
        if (isExisting) {
            Text(
                spanText(d.minutes),
                fontSize = 12.sp,
                fontWeight = FontWeight.ExtraBold,
                color = Brand.OrangeDeep,
                textAlign = androidx.compose.ui.text.style.TextAlign.End,
                modifier = Modifier.padding(top = 2.dp),
            )
        } else {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                StepperButton("−", onMinus)
                Text(
                    spanText(d.minutes),
                    fontSize = 12.sp,
                    fontWeight = FontWeight.ExtraBold,
                    color = Brand.OrangeDeep,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    modifier = Modifier.width(46.dp),
                )
                StepperButton("+", onPlus)
            }
        }
    }
}

@Composable
private fun StepperButton(text: String, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Box(
        Modifier.size(24.dp).clip(CircleShape).background(scheme.onSurface.copy(alpha = 0.08f)).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Text(text, fontSize = 14.sp, fontWeight = FontWeight.ExtraBold, color = scheme.onSurface) }
}

/** 90 → 1小时30分；45 → 45分钟 */
private fun spanText(min: Int): String = when {
    min < 60 -> "${min}分钟"
    min % 60 == 0 -> "${min / 60}小时"
    else -> "${min / 60}小时${min % 60}分"
}

@Composable
private fun StageTag(text: String, tint: Color) {
    Text(
        text,
        fontSize = 10.sp,
        fontWeight = FontWeight.ExtraBold,
        color = tint,
        modifier = Modifier.clip(CircleShape).background(tint.copy(alpha = 0.12f)).padding(horizontal = 7.dp, vertical = 1.dp),
    )
}

@Composable
private fun Field(value: String, onChange: (String) -> Unit, hint: String, minHeight: androidx.compose.ui.unit.Dp) {
    val scheme = MaterialTheme.colorScheme
    Box(
        Modifier
            .fillMaxWidth()
            .heightIn(min = maxOf(minHeight, 34.dp))
            .clip(RoundedCornerShape(10.dp))
            .background(scheme.onSurface.copy(alpha = 0.06f))
            .padding(horizontal = 10.dp, vertical = 8.dp),
    ) {
        BasicTextField(
            value = value,
            onValueChange = onChange,
            textStyle = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, color = scheme.onSurface),
            cursorBrush = SolidColor(Brand.Orange),
            modifier = Modifier.fillMaxWidth(),
            decorationBox = { inner ->
                if (value.isEmpty()) Text(hint, fontSize = 13.sp, lineHeight = 18.sp, color = scheme.onSurface.copy(alpha = 0.35f))
                inner()
            },
        )
    }
}

// ───────────────────────── 计划 ─────────────────────────

@Composable
private fun ResultContent(vm: AiAssistViewModel, ui: PlanUi.Result) {
    val scheme = MaterialTheme.colorScheme
    val p = ui.plan
    val today = LocalDate.now()
    Column(
        modifier = Modifier.fillMaxSize2().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (p.summary.isNotBlank()) {
            NoteCard(PURPLE) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(painterResource(R.drawable.ic_sparkle), null, tint = PURPLE, modifier = Modifier.size(14.dp))
                    Text("总结", fontSize = 12.sp, fontWeight = FontWeight.ExtraBold, color = PURPLE)
                }
                Text(p.summary, fontSize = 12.sp, lineHeight = 17.sp)
                if (p.adjusted > 0) {
                    Text("为避免时间重叠，已自动错开 ${p.adjusted} 项", fontSize = 11.sp, color = Brand.OrangeDeep, fontWeight = FontWeight.Bold)
                }
            }
        }

        if (p.topThree.isNotEmpty()) {
            Block {
                BlockTitle("今天最重要的 ${p.topThree.size} 件", Color(0xFFD9A400))
                p.topThree.forEachIndexed { i, (title, why) ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
                        Box(Modifier.padding(top = 1.dp).size(18.dp).clip(CircleShape).background(Brand.Orange), contentAlignment = Alignment.Center) {
                            Text("${i + 1}", fontSize = 10.sp, fontWeight = FontWeight.ExtraBold, color = Brand.Brown)
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                            Text(title, fontSize = 13.sp, lineHeight = 17.sp, fontWeight = FontWeight.SemiBold)
                            if (why.isNotBlank()) Text(why, fontSize = 11.sp, lineHeight = 15.sp, color = scheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }

        if (p.conflicts.isNotEmpty()) {
            Block {
                BlockTitle("冲突怎么处理", Brand.OrangeDeep)
                p.conflicts.forEach { c ->
                    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        Text(c.text, fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium)
                        if (c.resolution.isNotBlank()) Text("→ " + c.resolution, fontSize = 12.sp, lineHeight = 16.sp, color = scheme.onSurfaceVariant)
                    }
                }
            }
        }

        if (p.newTasks.isNotEmpty()) {
            Block {
                BlockTitle("排进日程的新任务 ${vm.checkedNew.size}/${p.newTasks.size}", GREEN)
                p.newTasks.forEachIndexed { i, n ->
                    if (i > 0) HorizontalDivider(thickness = 0.5.dp, color = scheme.outlineVariant)
                    NewRow(n, checked = n.key in vm.checkedNew, today = today) { vm.toggleNew(n.key) }
                }
            }
        }

        val mentioned = p.moves.filter { it.mentioned }
        val others = p.moves.filter { !it.mentioned }
        if (mentioned.isNotEmpty()) {
            Block {
                BlockTitle("你说的已有任务 · 只改时间 ${mentioned.count { it.id in vm.checkedMoves }}/${mentioned.size}", Color(0xFF3F7FCB))
                mentioned.forEachIndexed { i, m ->
                    if (i > 0) HorizontalDivider(thickness = 0.5.dp, color = scheme.outlineVariant)
                    MoveRow(m, checked = m.id in vm.checkedMoves, today = today) { vm.toggleMove(m.id) }
                }
            }
        }
        if (others.isNotEmpty()) {
            Block {
                BlockTitle("其他待办的调整 ${others.count { it.id in vm.checkedMoves }}/${others.size}", Brand.OrangeDeep)
                others.forEachIndexed { i, m ->
                    if (i > 0) HorizontalDivider(thickness = 0.5.dp, color = scheme.outlineVariant)
                    MoveRow(m, checked = m.id in vm.checkedMoves, today = today) { vm.toggleMove(m.id) }
                }
            }
        }

        if (p.moves.isEmpty() && p.newTasks.isEmpty()) {
            Text("AI 觉得现在的安排不需要调整。", fontSize = 13.sp, color = scheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 8.dp))
        }
    }
}

@Composable
private fun CheckBox(on: Boolean, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Box(
        Modifier
            .padding(top = 1.dp)
            .size(20.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(if (on) Brand.Orange else scheme.onSurface.copy(alpha = 0.10f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (on) Icon(Icons.Filled.Check, null, tint = Brand.Brown, modifier = Modifier.size(14.dp))
    }
}

@Composable
private fun NewRow(n: AiNewTask, checked: Boolean, today: LocalDate, onToggle: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
        CheckBox(checked, onToggle)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(n.title, fontSize = 13.sp, lineHeight = 17.sp, fontWeight = FontWeight.SemiBold)
            FlowRowTags {
                Tag(whenText(n.date, n.time, today) + if (n.time != null) "–" + endTime(n.time, n.minutes) else "", GREEN)
                Tag("${n.minutes} 分钟", scheme.onSurfaceVariant)
                if (n.priority > 0) Tag(listOf("", "低", "", "中", "", "高")[n.priority] + "优先级", if (n.priority >= 5) RED else Brand.OrangeDeep)
                n.project?.let { Tag("#$it", Color(0xFF3F7FCB)) }
            }
            n.parent?.let { Text("来自：$it", fontSize = 11.sp, color = scheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            if (n.reason.isNotBlank()) Text(n.reason, fontSize = 11.sp, lineHeight = 15.sp, color = PURPLE)
        }
    }
}

@Composable
private fun MoveRow(m: AiMove, checked: Boolean, today: LocalDate, onToggle: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
        CheckBox(checked, onToggle)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(cleanTitle(m.task.title), fontSize = 13.sp, lineHeight = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(whenText(m.task.date, m.task.time, today), fontSize = 11.sp, color = scheme.onSurfaceVariant)
                Text("→", fontSize = 11.sp, color = scheme.onSurfaceVariant)
                Text(
                    whenText(m.date, m.time, today) + if (m.time != null) "–" + endTime(m.time, com.carpe.ideashell.data.llm.PlanTime.estimate(m.task)) else "",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.ExtraBold,
                    color = Brand.OrangeDeep,
                )
            }
            if (m.reason.isNotBlank()) Text(m.reason, fontSize = 11.sp, lineHeight = 15.sp, color = PURPLE)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FlowRowTags(content: @Composable () -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) { content() }
}

@Composable
private fun Tag(text: String, tint: Color) {
    Text(
        text,
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        color = tint,
        maxLines = 1,
        modifier = Modifier.clip(CircleShape).background(tint.copy(alpha = 0.12f)).padding(horizontal = 7.dp, vertical = 1.dp),
    )
}

@Composable
private fun BlockTitle(text: String, color: Color) {
    Text(text, fontSize = 12.sp, fontWeight = FontWeight.ExtraBold, color = color)
}

@Composable
private fun Block(content: @Composable () -> Unit) {
    GlassSurface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp)) {
        Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) { content() }
    }
}

@Composable
private fun NoteCard(tint: Color, content: @Composable () -> Unit) {
    GlassSurface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp), tint = tint) {
        Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) { content() }
    }
}

// ───────────────────────── 文字 ─────────────────────────

private fun endTime(time: String?, minutes: Int): String {
    val s = com.carpe.ideashell.data.llm.PlanTime.minutes(time) ?: return ""
    return com.carpe.ideashell.data.llm.PlanTime.fmt(minOf(s + maxOf(minutes, 15), 24 * 60 - 1))
}

/** 「今天 14:00」「明天」「10/28 周二 09:00」；没有日期写「无日期」 */
private fun whenText(date: String?, time: String?, today: LocalDate): String {
    val d = parseDay(date) ?: return "无日期" + (time?.let { " $it" } ?: "")
    val day = when (ChronoUnit.DAYS.between(today, d)) {
        0L -> "今天"
        1L -> "明天"
        2L -> "后天"
        else -> "${d.monthValue}/${d.dayOfMonth} " + d.dayOfWeek.getDisplayName(java.time.format.TextStyle.SHORT, Locale.CHINA)
    }
    return day + (time?.let { " $it" } ?: "")
}
