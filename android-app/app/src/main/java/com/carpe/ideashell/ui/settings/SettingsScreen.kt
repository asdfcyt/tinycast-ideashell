package com.carpe.ideashell.ui.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.BuildConfig
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.R
import com.carpe.ideashell.data.asr.LocalAsrState
import com.carpe.ideashell.system.ExcerptService
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding

/**
 * 设置：首页 + 各个二级页面的路由。
 * 每个二级页面在自己的文件里（账号 / 输入 / AI / 重温 / 待办专注 / 入口一览 / 系统），
 * 这里只负责读取共用状态、标题栏和返回。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onOpenConnection: () -> Unit, onOpenRevisit: () -> Unit) {
    val context = LocalContext.current
    val container = (context.applicationContext as IdeashellApp).container
    val settings by container.settings.state.collectAsStateWithLifecycle()
    val ideashellConnected by container.credentials.ideashellConnected.collectAsStateWithLifecycle()
    val didaConnected by container.credentials.didaConnected.collectAsStateWithLifecycle()
    val ocrConfigured by container.credentials.ocrConfigured.collectAsStateWithLifecycle()
    val llmConfigured by container.credentials.llmConfigured.collectAsStateWithLifecycle()

    var batteryIgnored by remember { mutableStateOf(isIgnoringBatteryOptimizations(context)) }
    var excerptServiceOn by remember { mutableStateOf(ExcerptService.isEnabled(context)) }
    var overlayOn by remember { mutableStateOf(android.provider.Settings.canDrawOverlays(context)) }
    LifecycleResumeEffect(Unit) {
        overlayOn = android.provider.Settings.canDrawOverlays(context)
        batteryIgnored = isIgnoringBatteryOptimizations(context)
        excerptServiceOn = ExcerptService.isEnabled(context)
        onPauseOrDispose { }
    }

    var section by rememberSaveable { mutableStateOf<String?>(null) }
    // 「账号与连接」可以从多个页面跳进来：记住是从哪来的，返回时回到那里
    var accountsReturn by rememberSaveable { mutableStateOf<String?>(null) }
    fun parentSection(current: String?): String? = when (current) {
        SEC_LEXICON, SEC_VOICE_HISTORY -> SEC_VOICE
        SEC_ACCOUNTS -> accountsReturn
        else -> null
    }
    BackHandler(enabled = section != null) { section = parentSection(section) }

    val env = SettingsEnv(
        context = context,
        container = container,
        settings = settings,
        ideashellConnected = ideashellConnected,
        didaConnected = didaConnected,
        ocrConfigured = ocrConfigured,
        llmConfigured = llmConfigured,
        excerptServiceOn = excerptServiceOn,
        overlayOn = overlayOn,
        batteryIgnored = batteryIgnored,
        go = { target ->
            if (target == SEC_ACCOUNTS) accountsReturn = section
            section = target
        },
        onOpenConnection = onOpenConnection,
        onOpenRevisit = onOpenRevisit,
    )

    Scaffold(
        containerColor = Color.Transparent,
        contentWindowInsets = WindowInsets.statusBars,
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .padding(start = 16.dp, end = 16.dp, top = 8.dp),
        ) {
            val title = sectionTitle(section)
            // 标题栏固定在顶部，只有下面的设置项滚动
            if (title == null) {
                Text(
                    "设置",
                    style = MaterialTheme.typography.headlineSmall,
                    modifier = Modifier.padding(start = 4.dp, top = 16.dp, bottom = 12.dp),
                )
            } else {
                SubPageHeader(title, onBack = { section = parentSection(section) })
                Spacer(Modifier.height(12.dp))
            }

            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(bottom = LocalBottomBarPadding.current + 8.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                when (section) {
                    null -> SettingsHome(env)
                    SEC_ACCOUNTS -> AccountsSection(env)
                    SEC_RECORD -> RecordSection(env)
                    SEC_VOICE -> VoiceSection(env)
                    SEC_LEXICON -> LexiconPage()
                    SEC_VOICE_HISTORY -> VoiceHistoryPage()
                    SEC_OCR -> OcrSection(env)
                    SEC_AI -> AiSection(env)
                    SEC_REVISIT -> RevisitSection(env)
                    SEC_TODO -> TodoFocusSection(env)
                    SEC_QUICK -> EntriesSection(env)
                    SEC_BACKUP -> BackupSection(env)
                    SEC_BACKGROUND -> BackgroundSection(env)
                    else -> Unit
                }
            }
        }
    }
}

@Composable
private fun SettingsHome(env: SettingsEnv) {
    val container = env.container
    val settings = env.settings
    val localAsr by container.localAsr.state.collectAsStateWithLifecycle()
    val revisitToday by container.revisit.today.collectAsStateWithLifecycle()
    val cloudBackupAt = remember { container.backup.lastCloudBackupAt() }
    var showTheme by remember { mutableStateOf(false) }

    Group("账号") {
        SettingsItem(
            icon = Icons.Filled.AccountCircle,
            title = "账号与连接",
            summary = env.accountsSummary(),
            onClick = { env.go(SEC_ACCOUNTS) },
            trailing = { Chevron() },
        )
    }

    Group("输入方式") {
        SettingsItem(
            icon = Icons.Filled.Create,
            title = "文字记录",
            summary = "${settings.defaultTagsText.ifEmpty { "无默认标签" }} · ${settings.dailyFolder}",
            onClick = { env.go(SEC_RECORD) },
            trailing = { Chevron() },
        )
        SettingsItem(
            iconRes = R.drawable.ic_mic,
            title = "语音输入",
            summary = env.voiceSummary(localReady = localAsr is LocalAsrState.Ready),
            onClick = { env.go(SEC_VOICE) },
            trailing = { Chevron() },
        )
        SettingsItem(
            iconRes = R.drawable.ic_ocr,
            title = "OCR 输入",
            summary = env.ocrSummary(),
            onClick = { env.go(SEC_OCR) },
            trailing = { Chevron() },
        )
        SettingsItem(
            iconRes = R.drawable.ic_tile,
            title = "入口一览",
            summary = env.entriesSummary(),
            onClick = { env.go(SEC_QUICK) },
            trailing = { Chevron() },
        )
    }

    Group("AI") {
        SettingsItem(
            iconRes = R.drawable.ic_sparkle,
            title = "AI 与大模型",
            summary = env.aiSummary(),
            onClick = { env.go(SEC_AI) },
            trailing = { Chevron() },
        )
    }

    Group("功能") {
        SettingsItem(
            iconRes = R.drawable.ic_revisit,
            title = "重温",
            summary = env.revisitSummary(revisitToday),
            onClick = { env.go(SEC_REVISIT) },
            trailing = { Chevron() },
        )
        SettingsItem(
            iconRes = R.drawable.ic_nav_todo,
            title = "待办与专注",
            summary = env.todoSummary(),
            onClick = { env.go(SEC_TODO) },
            trailing = { Chevron() },
        )
    }

    Group("系统") {
        SettingsItem(
            icon = Icons.Filled.Settings,
            title = "主题",
            summary = settings.themeMode.label,
            onClick = { showTheme = true },
        )
        SettingsItem(
            icon = Icons.Filled.Share,
            title = "备份与迁移",
            summary = backupSummary(cloudBackupAt),
            onClick = { env.go(SEC_BACKUP) },
            trailing = { Chevron() },
        )
        SettingsItem(
            icon = Icons.Filled.Refresh,
            title = "后台同步",
            summary = env.backgroundSummary(),
            onClick = { env.go(SEC_BACKGROUND) },
            trailing = { Chevron() },
        )
    }

    Group("关于") {
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "拾忆",
            summary = "版本 ${BuildConfig.VERSION_NAME} · 记录自动同步到闪念贝壳与滴答清单",
            onClick = null,
        )
    }

    if (showTheme) {
        ThemeDialog(
            current = settings.themeMode,
            onSelect = { container.settings.setThemeMode(it) },
            onDismiss = { showTheme = false },
        )
    }
}
