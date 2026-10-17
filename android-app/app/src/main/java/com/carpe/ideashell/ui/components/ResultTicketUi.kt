package com.carpe.ideashell.ui.components

import android.widget.Toast
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.carpe.ideashell.data.focus.Celebration
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val PillAmber = Color(0xFFFFB14A)

/** 在后台把小票画成透明底的图；画好前是 null */
@Composable
internal fun rememberTicketBitmap(c: Celebration, todayMin: Int): ImageBitmap? {
    val bmp by produceState<ImageBitmap?>(null, c.id, todayMin) {
        value = withContext(Dispatchers.Default) { ResultTicket.render(c, todayMin, background = false).asImageBitmap() }
    }
    return bmp
}

/** 「保存到相册」小胶囊：存的是带深色底的整张图 */
@Composable
internal fun SaveTicketPill(c: Celebration, todayMin: Int, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var saving by remember(c.id) { mutableStateOf(false) }
    var saved by remember(c.id) { mutableStateOf(false) }
    Box(
        modifier
            .clip(CircleShape)
            .background(Color(0xCC14100D))
            .border(1.dp, PillAmber.copy(alpha = if (saved) 0.4f else 0.9f), CircleShape)
            .clickable(enabled = !saving) {
                saving = true
                scope.launch {
                    val ok = withContext(Dispatchers.Default) {
                        runCatching { ResultTicket.saveToGallery(context, ResultTicket.render(c, todayMin)) }.getOrDefault(false)
                    }
                    saving = false
                    if (ok) saved = true
                    Toast.makeText(context, if (ok) "成果图已保存到相册（Pictures/拾忆）" else "保存失败", Toast.LENGTH_SHORT).show()
                }
            }
            .padding(horizontal = 16.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            when {
                saving -> "保存中…"
                saved -> "已保存到相册"
                else -> "保存到相册"
            },
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            color = PillAmber,
        )
    }
}

/** 点「最近完成」的任务 / 「最近专注」的记录时弹出的小票；[onDetail] 非空时多一个「任务详情」 */
@Composable
fun TicketDialog(c: Celebration, onDismiss: () -> Unit, onDetail: (() -> Unit)? = null) {
    val today = c.todayMin
    val bmp = rememberTicketBitmap(c, today)
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        // 小票后面的页面磨砂，和底部抽屉同一个强度
        if (com.carpe.ideashell.ui.glass.rememberCrossWindowBlur()) {
            com.carpe.ideashell.ui.glass.BlurBehindWindow(radiusPx = com.carpe.ideashell.ui.glass.SheetBlurPx)
        }
        Column(
            Modifier
                .fillMaxWidth()
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            bmp?.let {
                Image(it, contentDescription = "成果小票", contentScale = ContentScale.FillWidth, modifier = Modifier.fillMaxWidth())
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(top = 4.dp)) {
                SaveTicketPill(c, today)
                if (onDetail != null) {
                    Box(
                        Modifier
                            .clip(CircleShape)
                            .background(Color(0xCC14100D))
                            .border(1.dp, Color(0x55FFFFFF), CircleShape)
                            .clickable { onDismiss(); onDetail() }
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                    ) { Text("任务详情", fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Color(0xFFF3E7D7)) }
                }
            }
        }
    }
}
