package com.carpe.ideashell

import android.app.Application
import android.content.Context
import com.carpe.ideashell.data.capture.CaptureProcessor
import com.carpe.ideashell.data.capture.CaptureRepository
import com.carpe.ideashell.data.capture.CaptureScheduler
import com.carpe.ideashell.data.db.AppDatabase
import com.carpe.ideashell.data.dida.DaySummaryService
import com.carpe.ideashell.data.dida.DidaApi
import com.carpe.ideashell.data.dida.HabitRepository
import com.carpe.ideashell.data.dida.TodoRepository
import com.carpe.ideashell.data.ideashell.DailyNoteService
import com.carpe.ideashell.data.ideashell.FolderRepository
import com.carpe.ideashell.data.ideashell.IdeashellApi
import com.carpe.ideashell.data.mcp.McpClient
import com.carpe.ideashell.data.mcp.McpEndpoints
import com.carpe.ideashell.data.notes.NotesRepository
import com.carpe.ideashell.data.ocr.TencentOcr
import com.carpe.ideashell.data.project.ProjectService
import com.carpe.ideashell.data.project.WorkspaceStore
import com.carpe.ideashell.data.secure.CredentialStore
import com.carpe.ideashell.data.secure.SecureStore
import com.carpe.ideashell.data.focus.FocusRepository
import com.carpe.ideashell.system.ExtraWidgets
import com.carpe.ideashell.system.FocusNotifier
import com.carpe.ideashell.system.TodoRefreshScheduler
import com.carpe.ideashell.system.TodoSurfaces
import com.carpe.ideashell.data.settings.SettingsStore
import java.time.LocalDate
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import okhttp3.OkHttpClient
import java.io.File
import java.util.concurrent.TimeUnit

class IdeashellApp : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        // 后台预热文件夹缓存，输入框里的 @文件夹 预览和保存都用它
        container.folders.refreshIfStale()
    }
}

/** 手写依赖容器。后续里程碑引入 Hilt 后由它取代。 */
class AppContainer(context: Context) {
    /** 进程级协程作用域：不随界面销毁而取消（保存后的同步要继续跑完） */
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val credentials = CredentialStore(SecureStore(context))
    val settings = SettingsStore(context)

    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(40, TimeUnit.SECONDS)
        .callTimeout(60, TimeUnit.SECONDS)
        .build()

    /** 腾讯云文字识别：相机页拍照 / 选图后识别文字 */
    val ocr = TencentOcr(http = http, credentials = credentials)

    val ideashell = McpClient(
        endpoint = McpEndpoints.IDEASHELL,
        http = http,
        tokenProvider = { credentials.ideashellKey },
    )

    val dida = McpClient(
        endpoint = McpEndpoints.DIDA,
        http = http,
        tokenProvider = { credentials.didaToken },
    )

    private val ideashellApi = IdeashellApi(ideashell)
    private val didaApi = DidaApi(dida)
    private val database = AppDatabase.create(context)
    private val dailyNotes = DailyNoteService(ideashellApi, settings)

    val folders = FolderRepository(
        api = ideashellApi,
        settings = settings,
        scope = appScope,
        hasCredential = { !credentials.ideashellKey.isNullOrBlank() },
    )

    val todos = TodoRepository(
        api = didaApi,
        cacheFile = File(context.filesDir, "todo_cache.json"),
        scope = appScope,
        hasCredential = { !credentials.didaToken.isNullOrBlank() },
    )

    val surfaces = TodoSurfaces(
        context = context.applicationContext,
        todos = todos,
        settings = settings,
        credentials = credentials,
        todayFocusMin = { daySummary.todayFocus.value?.takeIf { it.first == LocalDate.now() }?.second },
    )

    val processor = CaptureProcessor(
        dao = database.captureDao(),
        credentials = credentials,
        settings = settings,
        folders = folders,
        ideashell = ideashellApi,
        dida = didaApi,
        dailyNotes = dailyNotes,
        onTodoCreated = { todos.refresh(force = true) },
    )

    /** 回顾：时间线（含 Daily Note 拆条）/ 搜索 / 往日回顾 / 提及概览 / 笔记全文 */
    val notes = NotesRepository(
        ideashell = ideashellApi,
        dida = didaApi,
        dailyNotes = dailyNotes,
        hasDida = { !credentials.didaToken.isNullOrBlank() },
        todoSnapshot = { todos.state.value.overview },
    )

    val captures = CaptureRepository(
        dao = database.captureDao(),
        folders = folders,
        scheduler = CaptureScheduler(context),
        processor = processor,
        scope = appScope,
    )

    /** 项目 / 任务笔记 / 模板 / 习惯打卡兜底：本机的小数据（可丢弃重建） */
    val workspace = WorkspaceStore(File(context.filesDir, "workspace.json"), appScope)

    val habits = HabitRepository(api = didaApi, workspace = workspace)

    val daySummary = DaySummaryService(
        api = didaApi,
        dailyNotes = dailyNotes,
        hasDida = { !credentials.didaToken.isNullOrBlank() },
    )

    /** 专注：应用内倒计时，结束后写进滴答（create_focus），并把滴答里的专注读回来 */
    val focus = FocusRepository(
        context = context,
        api = didaApi,
        daySummary = daySummary,
        hasDida = { !credentials.didaToken.isNullOrBlank() },
        notifier = FocusNotifier(context.applicationContext),
    )

    /** 专注小部件 + 记录时间河小部件 */
    val widgets = ExtraWidgets(
        context = context.applicationContext,
        focus = focus,
        notes = notes,
        settings = settings,
        credentials = credentials,
        todayFocusMin = { daySummary.todayFocus.value?.takeIf { it.first == LocalDate.now() }?.second },
        cacheFile = File(context.filesDir, "river_widget_cache.json"),
    )

    /** 项目 / 任务笔记 / 项目主页（防弹笔记法） */
    val projects = ProjectService(
        ideashell = ideashellApi,
        dida = didaApi,
        notes = notes,
        captures = captures,
        habits = habits,
        daySummary = daySummary,
        store = workspace,
        hasDida = { !credentials.didaToken.isNullOrBlank() },
    )

    init {
        startSurfaceSync(context.applicationContext)
        // 进程被杀后重新起来：让专注通知 / 闹钟与存盘的状态一致，并补记到点没来得及记的专注
        focus.restore()
        appScope.launch { focus.settle() }
    }

    /**
     * 待办数据或「常驻通知」开关一变，就重绘小部件与通知；
     * 滴答连接 / 断开时安排或取消后台定时刷新。
     */
    @OptIn(FlowPreview::class)
    private fun startSurfaceSync(appContext: Context) {
        appScope.launch {
            combine(
                todos.state.map { it.overview }.distinctUntilChanged(),
                settings.state.map { it.persistentNotification to it.focusGoalMin }.distinctUntilChanged(),
                daySummary.todayFocus,
                focus.session,
                focus.pendingBreak,
            ) { _, _, _, _, _ -> }
                .debounce(300)
                .collect {
                    surfaces.updateAll()
                    widgets.updateFocus()
                }
        }
        appScope.launch {
            credentials.didaConnected.collect { connected ->
                if (connected) TodoRefreshScheduler.schedule(appContext) else TodoRefreshScheduler.cancel(appContext)
                surfaces.updateAll()
                widgets.updateAll()
            }
        }
    }
}
