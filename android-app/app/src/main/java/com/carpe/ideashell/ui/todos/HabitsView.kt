package com.carpe.ideashell.ui.todos

import com.carpe.ideashell.ui.glass.GlassButton
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.data.dida.Habit
import com.carpe.ideashell.ui.components.DividedRows
import com.carpe.ideashell.ui.components.EmptyNote
import com.carpe.ideashell.ui.components.GroupLabel
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.theme.Brand

/** 习惯打卡：今天需要打卡的滴答习惯，一点打卡（接口返回没有公开样例，解析为尽力而为） */
internal fun LazyListScope.habitsSection(
    ui: HabitUi,
    onRefresh: () -> Unit,
    onCheckin: (Habit) -> Unit,
) {
    val pending = ui.habits.count { !it.doneToday }
    item(key = "h-head") {
        GroupLabel(
            text = if (ui.habits.isEmpty()) "今日习惯" else "今日习惯 · 还差 $pending 个",
            trailing = { TextButton(onClick = onRefresh, enabled = !ui.loading) { Text("刷新") } },
        )
    }

    when {
        ui.loading && ui.habits.isEmpty() -> item(key = "h-loading") {
            Box(Modifier.fillMaxWidth().padding(vertical = 40.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        }

        ui.error != null && ui.habits.isEmpty() -> item(key = "h-error") {
            EmptyNote("没能加载习惯", ui.error)
        }

        ui.habits.isEmpty() -> item(key = "h-empty") {
            EmptyNote(
                "今天没有需要打卡的习惯",
                "习惯来自滴答清单。在滴答里创建习惯后，这里会显示今天需要打卡的；项目「记一条」时，同名习惯会自动打卡。",
            )
        }

        else -> item(key = "h-list") {
            ListGroup(Modifier.animateItem()) {
                DividedRows(ui.habits.sortedBy { it.doneToday }) { h ->
                    Row(
                        modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(start = 16.dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(h.name, style = MaterialTheme.typography.bodyLarge)
                            if (h.label.isNotEmpty()) {
                                Text(
                                    "目标 ${h.label}",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                        if (h.doneToday) {
                            Row(
                                modifier = Modifier.padding(end = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(4.dp),
                            ) {
                                Icon(Icons.Filled.Check, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
                                Text("已打卡", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                            }
                        } else {
                            GlassButton(onClick = { onCheckin(h) }) { Text("打卡") }
                        }
                    }
                }
            }
        }
    }
}
