import AppKit
import Foundation
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case today, focus, todos, calendar, review, insights, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今天"
        case .todos: return "待办"
        case .calendar: return "日历"
        case .focus: return "行动"
        case .insights: return "洞察"
        case .review: return "回顾"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .todos: return "checklist"
        case .calendar: return "calendar"
        case .focus: return "target"
        case .insights: return "chart.bar.xaxis"
        case .review: return "water.waves"
        case .settings: return "gearshape"
        }
    }
}

struct NoteRef: Hashable {
    let id: String
    var fallbackTitle: String?
}

/// 弹层里的页面：笔记详情 / 任务详情（可以互相跳转，带返回栈）
final class PaneState: ObservableObject {
    @Published var page: SheetPage?
    /// 河里被选中的那一行（Daily Note 同一天的多条共用一篇笔记，靠它区分是哪一条）
    @Published var entry: String?

    func select(_ p: SheetPage, entry: String?) {
        page = p
        self.entry = entry
    }

    func clear() { page = nil; entry = nil }

    func isNote(_ id: String, entry key: String? = nil) -> Bool {
        guard case let .note(r)? = page, r.id == id else { return false }
        return entry == key
    }

    func isTask(_ id: String) -> Bool { if case let .task(t)? = page { return t.id == id }; return false }
}

/// 只在选中状态变化时刷新自己：把「是不是选中」算出来交给内容
struct PaneSelection<Content: View>: View {
    @ObservedObject var pane: PaneState
    let match: (PaneState) -> Bool
    @ViewBuilder var content: (Bool) -> Content

    var body: some View { content(match(pane)) }
}

enum SheetPage: Hashable {
    case note(NoteRef)
    case task(DidaTask)
}

@MainActor
final class AppModel: ObservableObject {
    let credentials = CredentialStore()
    let ideashell: IdeashellApi
    let dida: DidaApi
    private let ideashellMcp: McpClient
    private let didaMcp: McpClient
    /// 结审（审计工作台）的 MCP 服务：地址和 API Key 在设置里填，见 Data/SjzApi.swift
    var sjz: SjzApi

    @Published var section: AppSection = .today
    @Published var sheetStack: [SheetPage] = []
    @Published var selectedProject: String?

    // 凭证（设置页编辑用）
    @Published var ideashellKeyInput: String
    @Published var didaTokenInput: String
    @Published var sjzKeyInput: String
    @Published var sjzEndpoint: String = UserDefaults.standard.string(forKey: SjzApi.endpointKey) ?? SjzApi.defaultEndpoint
    /// 结审里当前钉住的项目 / 取证单 / 法规（保存证据、法规、线索都以它为准）
    @Published var sjzEnabled: Bool = (UserDefaults.standard.object(forKey: "sjz.enabled") as? Bool) ?? true {
        didSet {
            guard oldValue != sjzEnabled else { return }
            UserDefaults.standard.set(sjzEnabled, forKey: "sjz.enabled")
            CaptureParser.sjzOn = hasSjz
            IslandController.shared.syncSjzNow()
            Task { @MainActor in
                await refreshSjzOverview(force: true)
                if sjzEnabled { await refreshSjzTarget(); await refreshSjzProjects() }
            }
        }
    }
    @Published var sjzPin = SjzPin()
    /// 结审任务概览：只缓存在本机，不写入滴答清单 / 闪念贝壳
    @Changed var sjzOverview: SjzOverview? = AppModel.readCache("sjz-overview.json")
    @Published var sjzProjects: [SjzApi.Project] = []
    /// 岛上显示的保存目标（项目名）；设置里读到后缓存
    @Changed var sjzTargetTitle: String = ""
    // AI 模型（OpenAI 兼容接口）：Key 存本机凭证文件，地址和模型名存偏好
    @Published var llmKeyInput: String
    @Published var llmBaseUrl: String = UserDefaults.standard.string(forKey: "llm.baseUrl") ?? "https://dashscope.aliyuncs.com/compatible-mode/v1"
    @Published var llmModel: String = UserDefaults.standard.string(forKey: "llm.model") ?? "qwen-plus"

    // 笔记时间线
    @Changed var timeline: [NoteInfo] = [] {
        didSet { todayMemo = nil }
    }
    @Changed var timelineDays = 0
    @Changed var notesLoading = false
    @Changed var notesError: String?
    @Changed var notesTruncated = false
    @Published var searchQuery = ""
    @Changed var searchResults: [NoteInfo]?
    @Changed var searching = false

    // 待办
    @Changed var overview: DidaOverview? {
        didSet {
            // 读回来的和原来一样（编辑 / 删除后的静默刷新常常如此）就什么都不做
            guard oldValue != overview else { return }
            todayMemo = nil
            projectProgressMemo = nil
            Notifier.shared.syncTodos(overview)
        }
    }
    /// 「项目进展」的算结果缓存：它要把每个项目和每条待办两两比对，今天页每次重绘都算会很吃 CPU；待办 / 项目变了才作废
    var projectProgressMemo: Double??
    /// 今天页的过滤 / 排序结果缓存，见 TodayData.swift；待办 / 笔记 / 今天的 Daily Note 变了就作废
    var todayMemo: (day: String, data: TodayData)?
    @Changed var todosLoading = false
    @Changed var todosError: String?
    @Changed var lastUndo: DidaTask?

    // 备份（项目 / 任务笔记）
    @Published var backup: BackupFile? {
        didSet { projectProgressMemo = nil }
    }
    /// 在 Mac 上创建的任务笔记（key 同备份里的 `dida:<taskId>`）；手机下次备份后会带上它们
    @Published var localTaskNotes: [String: TaskNoteRef] = [:]
    /// 本机新建 / 找回的项目主页（关键词 → 笔记 id），见 ProjectHome.swift
    @Published var localHomes: [String: String] = [:]
    /// AI 洞察（按统计范围 7 / 14 / 30 天各存一份），见 AIInsight.swift
    @Published var aiInsights: [Int: AIInsight] = [:]
    @Changed var aiInsightLoading = false
    @Changed var aiInsightError: String?
    @Changed var creatingTaskNote = false
    /// 今天页的「往日回顾」：1 周 / 1 个月 / 3 个月 / 1 年前的今天写过的笔记
    @Changed var memory: [MemoryItem] = []
    /// 今天页热力图：最近 26 周每天 Daily Note 里记了几条
    @Changed var heat: [String: Int] = [:]
    @Changed var heatLoading = false
    /// 今天页的「今天的笔记」：今天 Daily Note 的条目。放在这里而不是页面里，切走再切回来不会清空重读
    @Changed var dailyToday: DailyDay? {
        didSet { todayMemo = nil }
    }
    var dailyTodayDay = ""
    /// 「从这条日记新建笔记」的弹窗（今天页和回顾页的右键菜单共用，由根视图弹出）
    @Published var newNoteDraft: NewNoteDraft?
    /// 正在批量改期 / 自动排期
    @Changed var scheduling = false
    /// 正在把专注中的一条记录写进任务笔记
    @Changed var recording = false
    /// 每日专注目标（分钟），今天页的专注环以它为满环；设置里改
    @Published var focusGoalMin: Int = {
        let v = UserDefaults.standard.integer(forKey: "focus.goalMin")
        return v > 0 ? min(max(v, 10), 720) : 120
    }() {
        didSet { UserDefaults.standard.set(focusGoalMin, forKey: "focus.goalMin") }
    }
    /// 项目「提及的笔记」的搜索结果缓存（只在内存里）
    var mentionCache: [String: (at: Date, notes: [NoteInfo])] = [:]
    @Changed var backupLoading = false
    @Changed var backupError: String?

    // 回顾
    @Published var reviewDays = 14
    @Published var review: ReviewData?
    @Changed var reviewLoading = false
    @Changed var reviewError: String?

    // 日历
    @Published var calendarMonth: Date = Day.startOfDay(Date())
    @Published var calendarMode: CalendarMode = .month
    /// 日历里选中的那一天（日 / 周视图以它为准）
    @Published var calendarDay: String = Day.today()
    @Changed var calendarTasks: [String: DidaTask] = [:]
    @Changed var calendarNotes: [String: [NoteInfo]] = [:]
    @Changed var calendarLoading = false
    /// 日历已读过的日期范围（及读取时间），用来判断切到周 / 日视图时要不要重读
    var calendarCover: (from: String, to: String, at: Date)?
    @Changed var calendarError: String?

    // 快速记录
    @Published var showQuickAdd = false
    /// 打开万能输入时预填的文字 / 指定类型 / 默认日期（日历里「添加待办」用）
    @Published var quickAddText = ""
    @Published var quickAddKind: CaptureKind?
    @Changed var notice: String?
    @Published var quickAddDate: String?
    /// 日历时间轴上点出来的时间（HH:mm），万能输入里没写时间的待办用它
    @Published var quickAddTime: String?
    /// 日历时间轴上双击出来的「新建待办」草稿；有草稿时右侧面板是新建表单
    @Published var calendarDraft: CalendarDraft?
    /// 右键「编辑任务…」：打开详情后由详情页弹出编辑框（存任务 id）
    @Published var pendingEditTask: String?
    /// 日历右侧面板里选中的任务详情（点时间轴 / 当天列表里的任务，在右边展开，不再弹页面）
    let calPane = PaneState()
    /// 快速启动最近一次的梳理结果（30 分钟内再打开直接用）
    var quickStartCache: QuickStartPlan?
    /// 上次读回来的待办 / 笔记指纹；和这次不一样就说明数据有变化（见 HistoryCache.swift）
    var overviewFP = 0
    var timelineFP = 0
    var historyDirty = false

    // 回顾页：顶部的新入口（时间河 / 洞察 / 专注）和右侧详情
    /// 回顾页右侧详情的选中状态。单独一个对象：选中变化只刷新右侧和被选行，不会让整条河重新绘制
    let pane = PaneState()
    let focus: FocusStore

    // 回顾：时间河
    /// 数据读过多久内再进页面不重新请求（切页面时不卡）；手动刷新 / 改范围不受影响
    var loadStamps: [String: (key: String, at: Date)] = [:]
    @Published var riverPreset: RangePreset = .last7
    @Published var river: TimelineData?
    @Changed var riverLoading = false
    @Changed var riverError: String?
    /// 被用户翻转过「展开 / 收起」的日子（默认只展开今天、昨天）
    @Published var riverFlipped: Set<String> = []

    // 日历：法定节假日 / 调休
    @Changed var holidays: [String: HolidayEntry] = [:]
    lazy var daily = DailyService(api: ideashell)

    var noteCache: [String: NoteDetail] = [:]
    /// 最近一次 `submitCapture` 创建出来的东西（发件箱用它支持「撤销」）
    var lastCreated: UndoRecord?
    private var refreshTimer: Timer?
    private var activeObserver: NSObjectProtocol?
    private var lastQuick = Date()
    private var inflight = Set<String>()

    init() {
        let cred = credentials
        let im = McpClient(endpoint: McpEndpoints.ideashell) { cred.ideashellKey }
        let dm = McpClient(endpoint: McpEndpoints.dida) { cred.didaToken }
        ideashellMcp = im
        didaMcp = dm
        sjz = SjzApi.make(endpoint: UserDefaults.standard.string(forKey: SjzApi.endpointKey) ?? SjzApi.defaultEndpoint) { cred.sjzKey }
        ideashell = IdeashellApi(mcp: im)
        dida = DidaApi(mcp: dm)
        focus = FocusStore(api: DidaApi(mcp: dm)) { !cred.didaToken.trimmed.isEmpty }
        ideashellKeyInput = cred.ideashellKey
        didaTokenInput = cred.didaToken
        sjzKeyInput = cred.sjzKey
        llmKeyInput = cred.llmKey
        focus.onMessage = { [weak self] text in self?.showNotice(text) }
        BreakSession.shared.attach(focus)

        if let json = LocalStore.read("backup.json"), let file = try? BackupService.decode(json) { backup = file }
        if let json = LocalStore.read("tasknotes.json"), let d = json.data(using: .utf8),
           let m = try? JSONDecoder().decode([String: TaskNoteRef].self, from: d) { localTaskNotes = m }
        if let json = LocalStore.read("homes.json"), let d = json.data(using: .utf8),
           let m = try? JSONDecoder().decode([String: String].self, from: d) { localHomes = m }
        // 上次的待办 / 笔记先摆出来，网络回来再悄悄更新（启动时不用对着空白等）
        overview = Self.readCache("overview.json")
        timeline = Self.readCache("timeline.json") ?? []
        heat = Self.readCache("heat.json") ?? [:]
        if let c: DailyTodayCache = Self.readCache("daily-today.json"), c.day == Day.today() {
            dailyToday = c.data
            dailyTodayDay = c.day
        }
        if !timeline.isEmpty { timelineDays = 2 }
        if !hasIdeashell && !hasDida { section = .settings }
    }

    // MARK: - 本机缓存（只存最近一次的待办 / 笔记，下次启动先显示它）

    static func readCache<T: Decodable>(_ name: String) -> T? {
        guard let text = LocalStore.read(name), let d = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    static func writeCache<T: Encodable>(_ name: String, _ value: T) {
        guard let d = try? JSONEncoder().encode(value), let text = String(data: d, encoding: .utf8) else { return }
        LocalStore.write(name, text)
    }

    /// 备份缓存文件有多久没更新了
    private func backupCacheAge() -> TimeInterval? {
        let url = LocalStore.dir.appendingPathComponent("backup.json")
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(date)
    }

    var hasIdeashell: Bool { !credentials.ideashellKey.trimmed.isEmpty }
    var hasDida: Bool { !credentials.didaToken.trimmed.isEmpty }
    /// 已启用并填了 Key（关掉开关后，岛上的结审区、结审任务、提醒都会消失）
    var hasSjz: Bool { sjzEnabled && !credentials.sjzKey.trimmed.isEmpty }

    // MARK: - 启动 / 定时刷新

    func start() {
        guard refreshTimer == nil else { return }
        AppModel.current = self
        focus.onTicket = { TicketController.shared.present($0) }
        IslandController.shared.start(model: self)
        QuickAddPanelController.shared.start(model: self)
        CaptureOutbox.shared.resume(model: self)
        VoiceController.shared.start(model: self)
        VoicePanelHost.shared.start()
        restoreHistoryCaches()
        loadAIInsights()
        Task { await refreshAll(startup: true) }
        Task { await loadHolidays() }
        startSjzEvents()
        CaptureParser.sjzOn = hasSjz
        focus.sjzSink = { [weak self] p in try await self?.sjzRecordFocus(p) }
        Task { await focus.settle(); await focus.refresh(); stamp("focus", key: "f") }
        // 定时刷新（后台也做：灵动岛 / 菜单栏上的数字要一直是新的）；回到前台时，离上次刷新超过 2 分钟再补一次
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshQuick() }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.onBecameActive() }
        }
    }

    private func onBecameActive() async {
        CaptureOutbox.shared.resume(model: self)
        guard Date().timeIntervalSince(lastQuick) > 120 else { return }
        await refreshQuick()
        // 当前页的历史数据超过缓存时间才重读
        switch section {
        case .calendar: await loadCalendar(ifStale: true)
        case .review: await loadRiver(silent: true, ifStale: true)
        case .insights: await loadReview(ifStale: true)
        default: break
        }
    }

    /// 手动刷新（⌘R）= 全部重读；启动时只读必要的（备份缓存还新就不再拉那篇大笔记）
    func refreshAll(startup: Bool = false) async {
        lastQuick = Date()
        if !startup { daily.clearPast() }
        let skipBackup = startup && (backupCacheAge().map { $0 < 1800 } ?? false) && backup != nil
        await runAll([
            { await self.loadTimeline(silent: !self.timeline.isEmpty) },
            { await self.loadOverview(silent: self.overview != nil) },
            { if !skipBackup { await self.loadBackup() } },
        ])
        switch section {
        case .calendar: await loadCalendar(ifStale: startup)
        case .focus: await focus.settle(); await focus.refresh()
        case .review: await loadRiver(silent: river != nil, ifStale: startup)
        case .insights: await loadReview(ifStale: startup)
        default: break
        }
    }

    /// 定时刷新：待办 + 时间线最近部分
    func refreshQuick() async {
        lastQuick = Date()
        await runAll([
            { await self.loadOverview(silent: true) },
            { await self.loadTimeline(silent: true) },
        ])
        applyHistoryChanges()
    }

    /// 已保存的 AI 模型 Key（保存后才算，不看输入框里还没保存的）
    var hasLlm: Bool { !credentials.llmKey.trimmed.isEmpty }

    var llm: LlmClient { LlmClient(baseURL: llmBaseUrl, model: llmModel, key: credentials.llmKey) }

    func saveLlm() {
        credentials.setLlmKey(llmKeyInput.trimmed)
        let base = llmBaseUrl.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        llmBaseUrl = base.isEmpty ? "https://dashscope.aliyuncs.com/compatible-mode/v1" : base
        llmModel = llmModel.trimmed.isEmpty ? "qwen-plus" : llmModel.trimmed
        UserDefaults.standard.set(llmBaseUrl, forKey: "llm.baseUrl")
        UserDefaults.standard.set(llmModel, forKey: "llm.model")
        objectWillChange.send()
    }

    func saveCredentials() async {
        credentials.update(ideashell: ideashellKeyInput.trimmed, dida: didaTokenInput.trimmed)
        await ideashellMcp.reset()
        await didaMcp.reset()
        noteCache.removeAll()
        await refreshAll()
    }

    // MARK: - 笔记

    private func isUserNote(_ n: NoteInfo) -> Bool { !BackupService.isBackupNote(n) }

    func loadTimeline(silent: Bool = false) async {
        guard hasIdeashell else { return }
        if !silent { notesLoading = true }
        defer { notesLoading = false }
        // 只有「今天」页用到最近的笔记：读最近 2 天就够，别每次刷新都拉两周
        let days = max(timelineDays, 2)
        let start = Day.startOfDay(Day.cal.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date())
        do {
            let r = try await ideashell.notesInRange(start, Date().addingTimeInterval(120))
            timeline = r.notes.filter(isUserNote)
            let fp = Self.fingerprint(timeline)
            if timelineFP != 0 && fp != timelineFP { historyDirty = true }
            timelineFP = fp
            Self.writeCache("timeline.json", timeline)
            timelineDays = days
            notesTruncated = r.truncated
            notesError = nil
        } catch {
            if !silent || timeline.isEmpty { notesError = error.localizedDescription }
        }
    }

    func loadMoreNotes() async {
        guard hasIdeashell, !notesLoading else { return }
        notesLoading = true
        defer { notesLoading = false }
        let newDays = timelineDays + 14
        let end = Day.startOfDay(Day.cal.date(byAdding: .day, value: -(timelineDays - 1), to: Date()) ?? Date())
        let start = Day.startOfDay(Day.cal.date(byAdding: .day, value: -(newDays - 1), to: Date()) ?? Date())
        do {
            let r = try await ideashell.notesInRange(start, end)
            var seen = Set(timeline.map(\.id))
            for n in r.notes.filter(isUserNote) where seen.insert(n.id).inserted { timeline.append(n) }
            timeline.sort { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            timelineDays = newDays
            notesError = nil
        } catch {
            notesError = error.localizedDescription
        }
    }

    func search() async {
        let q = searchQuery.trimmed
        guard !q.isEmpty else { searchResults = nil; return }
        guard hasIdeashell else { return }
        searching = true
        defer { searching = false }
        do {
            searchResults = try await ideashell.searchNotes(q, limit: 20).filter(isUserNote)
            notesError = nil
        } catch {
            notesError = error.localizedDescription
        }
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = nil
    }

    func noteDetail(_ id: String) async throws -> NoteDetail {
        if let c = noteCache[id] { return c }
        let d = try await ideashell.noteFull(id)
        noteCache[id] = d
        return d
    }

    func openNote(_ id: String, title: String? = nil) {
        present(.note(NoteRef(id: id, fallbackTitle: title)))
    }

    func openTask(_ task: DidaTask) {
        // 日历里（年视图除外）：在右侧面板展开，和系统日历点日程一样
        if section == .calendar && calendarMode != .year {
            calendarDraft = nil
            calPane.select(.task(task), entry: nil)
        } else {
            present(.task(task))
        }
    }

    /// 打开任务详情并直接进入编辑
    func editTask(_ task: DidaTask) {
        openTask(task)
        pendingEditTask = task.id
    }

    /// 弹出页面。已经在显示同一页就不重复叠一层（双击会连续触发两次）
    func present(_ page: SheetPage) {
        if let last = sheetStack.last {
            if last == page { return }
            if case let .note(a) = last, case let .note(b) = page, a.id == b.id { return }
            if case let .task(a) = last, case let .task(b) = page, a.id == b.id { return }
        }
        sheetStack.append(page)
    }

    // MARK: - 回顾页右侧详情：单击在右边展开，双击弹出页面

    func paneNote(_ id: String, title: String? = nil, entry: String? = nil) {
        pane.select(.note(NoteRef(id: id, fallbackTitle: title)), entry: entry)
    }
    func paneTask(_ task: DidaTask) { pane.select(.task(task), entry: nil) }

    /// 搜索：从笔记结果里选一条；跳到时间河，搜索结果替换河
    func searchAndShow() async {
        await search()
    }

    func popSheet() { if !sheetStack.isEmpty { sheetStack.removeLast() } }
    func closeSheets() { sheetStack.removeAll() }

    func goToProject(_ keyword: String) {
        closeSheets()
        selectedProject = keyword
        section = .focus
    }

    // MARK: - 任务笔记（融合）

    /// 备份里的任务笔记 + 本机创建的（本机的优先）
    var allTaskNotes: [String: TaskNoteRef] {
        (backup?.workspace.taskNotes ?? [:]).merging(localTaskNotes) { _, local in local }
    }

    /// 任务 id → 它的任务笔记
    func taskNote(for taskId: String) -> TaskNoteRef? {
        let key = "dida:" + taskId
        return localTaskNotes[key] ?? backup?.workspace.taskNotes[key]
    }

    /// 同上；对应关系里没有时，再看任务备注里有没有「任务笔记：<链接>」（手机写回滴答的）
    func taskNote(forTask task: DidaTask) -> TaskNoteRef? {
        if let r = taskNote(for: task.id) { return r }
        if let id = TaskNoteBuilder.linkedNoteId(in: task.content) { return TaskNoteRef(noteId: id, deliverable: nil, project: nil, createdAt: nil, archived: nil) }
        return nil
    }

    /// 笔记 id → 它是哪个任务的任务笔记
    func taskOfNote(_ noteId: String) -> (taskId: String, ref: TaskNoteRef)? {
        guard let hit = allTaskNotes.first(where: { $0.value.noteId == noteId && $0.key.hasPrefix("dida:") }) else { return nil }
        return (String(hit.key.dropFirst(5)), hit.value)
    }

    /// 在 Mac 上给任务新建任务笔记（与安卓端同一份模板）：建笔记 → 记下对应关系 → 把链接写回滴答任务备注
    @discardableResult
    func createTaskNote(_ task: DidaTask, deliverable: String, purpose: String, steps: String) async -> Bool {
        if SjzTasks.owns(task.id) { showNotice("结审任务的记录保存在结审里，不创建任务笔记"); return false }
        guard hasIdeashell else { showNotice("先到「设置」填写闪念贝壳 API Key"); return false }
        guard !creatingTaskNote else { return false }
        creatingTaskNote = true
        defer { creatingTaskNote = false }
        let t = localTask(task.id) ?? task
        let goal = deliverable.trimmed.isEmpty ? t.cleanTitle : deliverable.trimmed
        let project = projectOf(t)?.keyword
        let body = TaskNoteBuilder.body(
            taskTitle: t.cleanTitle, deliverable: goal, purpose: purpose, steps: steps,
            taskLink: didaTaskURL(t.projectId, t.id).absoluteString
        )
        do {
            let created = try await ideashell.createNote(
                title: TaskNoteBuilder.title(t.cleanTitle), body: body,
                tags: ["任务笔记"] + (project.map { [$0] } ?? [])
            )
            guard let noteId = TaskNoteBuilder.noteId(from: created) else {
                throw NSError(domain: "Shiyi", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有从创建结果里取到笔记 id：" + String(created.prefix(100))])
            }
            let ref = TaskNoteRef(noteId: noteId, deliverable: goal, project: project, createdAt: Int64(Date().timeIntervalSince1970 * 1000), archived: nil)
            localTaskNotes["dida:" + t.id] = ref
            if let d = try? JSONEncoder().encode(localTaskNotes), let text = String(data: d, encoding: .utf8) {
                LocalStore.write("tasknotes.json", text)
            }
            // 链接写回滴答，在滴答里也能找到它（失败不影响主流程）
            if hasDida {
                let line = "任务笔记：" + noteURL(noteId).absoluteString
                let content = t.content.trimmed.isEmpty ? line : t.content + "\n" + line
                try? await dida.setContent(t, content: content)
            }
            invalidateHistory()
            showNotice("已创建任务笔记")
            return true
        } catch {
            showNotice("创建任务笔记失败：" + error.localizedDescription)
            return false
        }
    }

    /// 笔记 id → 它是哪个项目的主页
    func projectOfHome(_ noteId: String) -> String? {
        allHomes.first(where: { $0.value == noteId })?.key
    }

    /// 本地已有的任务；没有就向滴答要
    func findTask(_ id: String) async -> DidaTask? {
        if let t = localTask(id) { return t }
        return await dida.fetchTask(id)
    }

    func localTask(_ id: String) -> DidaTask? {
        // 不拼接数组：右键菜单 / 行视图每次求值都会调用，拼一次就是复制全部待办
        if let ov = overview {
            if let t = ov.overdue.first(where: { $0.id == id }) { return t }
            if let t = ov.upcoming.first(where: { $0.id == id }) { return t }
            if let t = ov.undated.first(where: { $0.id == id }) { return t }
            if let t = ov.done.first(where: { $0.id == id }) { return t }
        }
        return calendarTasks[id]
    }

    /// 项目：任务属于哪个本地项目（取第一个命中的）
    func projectOf(_ task: DidaTask) -> Project? {
        projects.first { $0.matches(task.title, tags: task.tags) }
    }

    // MARK: - 待办

    func loadOverview(silent: Bool = false) async {
        guard hasDida else { return }
        if !silent { todosLoading = true }
        defer { todosLoading = false }
        do {
            let fresh = mergeSjz(try await dida.fetchOverview())
            let changed = fresh != overview
            overview = fresh
            let fp = Self.fingerprint(fresh)
            if overviewFP != 0 && fp != overviewFP { historyDirty = true }
            overviewFP = fp
            if changed && fresh.warning == nil { Self.writeCache("overview.json", fresh) }
            todosError = overview?.warning
        } catch {
            if !silent || overview == nil { todosError = error.localizedDescription }
        }
    }

    func complete(_ task: DidaTask) async {
        guard var ov = overview else { return }
        ov = ov.withoutTask(task.id)
        var finished = task
        finished.done = true
        finished.completedAt = Int64(Date().timeIntervalSince1970 * 1000)
        ov.done.insert(finished, at: 0)
        overview = ov
        if var c = calendarTasks[task.id] { c.done = true; calendarTasks[task.id] = c }
        do {
            try await dida.complete(task)
            invalidateHistory()
            lastUndo = finished
            Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                await loadOverview(silent: true)
            }
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if lastUndo?.id == task.id { lastUndo = nil }
            }
        } catch {
            todosError = "完成失败：\(error.localizedDescription)"
            await loadOverview(silent: true)
        }
    }

    func undoComplete(_ task: DidaTask) async {
        do {
            try await dida.reopen(task)
            invalidateHistory()
            if var c = calendarTasks[task.id] { c.done = false; calendarTasks[task.id] = c }
            if lastUndo?.id == task.id { lastUndo = nil }
            await loadOverview(silent: true)
        } catch {
            todosError = "撤销失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 备份（项目）

    func loadBackup() async {
        guard hasIdeashell else { return }
        backupLoading = true
        defer { backupLoading = false }
        do {
            let r = try await BackupService.pull(api: ideashell, noteId: credentials.backupNoteId)
            backup = r.file
            backupError = nil
            LocalStore.write("backup.json", r.json)
            credentials.setBackupNoteId(r.noteId)
        } catch {
            // 记着的备份笔记 id 失效（被删）时清掉，下次按标题重新找
            if credentials.backupNoteId != nil {
                credentials.setBackupNoteId(nil)
                if let r = try? await BackupService.pull(api: ideashell, noteId: nil) {
                    backup = r.file
                    backupError = nil
                    LocalStore.write("backup.json", r.json)
                    credentials.setBackupNoteId(r.noteId)
                    return
                }
            }
            backupError = error.localizedDescription
        }
    }

    var projects: [Project] { backup?.workspace.projects ?? [] }

    // MARK: - 回顾

    func loadReview(ifStale: Bool = false) async {
        guard hasIdeashell || hasDida else { return }
        let stampKey = "\(reviewDays)|\(Day.today())"
        if ifStale, isFresh("review", key: stampKey), review != nil { return }
        guard beginLoad("review", ifStale: ifStale) else { return }
        defer { endLoad("review") }
        // 已经有这个范围的数据时在后台悄悄更新，不转圈
        reviewLoading = review == nil || review?.days != reviewDays
        defer { reviewLoading = false }
        reviewError = nil
        let days = reviewDays
        let today = Day.today()
        let from = Day.add(today, days: -(days - 1))
        let start = Day.startOfDay(Day.parse(from) ?? Date())

        var notes: [NoteInfo] = []
        var truncated = false
        if hasIdeashell {
            do {
                let r = try await ideashell.notesInRange(start, Date().addingTimeInterval(120))
                notes = r.notes.filter(isUserNote)
                truncated = r.truncated
            } catch {
                reviewError = error.localizedDescription
            }
        }
        var done: [DidaTask] = []
        var todoError: String?
        if hasDida {
            do { done = try await dida.completedInRange(from, today) }
            catch { todoError = error.localizedDescription }
        }
        review = ReviewData.compute(
            days: days,
            notes: notes,
            done: done,
            focusLog: backup?.workspace.focusLog ?? [],
            projects: projects,
            truncated: truncated,
            todoError: todoError
        )
        if reviewError == nil && todoError == nil { stamp("review", key: stampKey) }
        reviewLoading = false
        await loadPreviousPeriod(days: days, today: today)
        saveReviewCache()
    }

    /// 洞察里「较上一个周期」的对比：主数据出来之后再悄悄补读上一段同样长度的时间
    private func loadPreviousPeriod(days: Int, today: String) async {
        let prevTo = Day.add(today, days: -days)
        let prevFrom = Day.add(prevTo, days: -(days - 1))
        var notes: [NoteInfo] = []
        var done: [DidaTask] = []
        if hasIdeashell, let r = try? await ideashell.notesInRange(Day.startOfDay(Day.parse(prevFrom) ?? Date()), Day.startOfDay(Day.parse(Day.add(prevTo, days: 1)) ?? Date())) {
            notes = r.notes.filter(isUserNote)
        }
        if hasDida { done = (try? await dida.completedInRange(prevFrom, prevTo)) ?? [] }
        guard reviewDays == days, review != nil else { return }
        review?.prev = ReviewData.totals(from: prevFrom, to: prevTo, notes: notes, done: done, focusLog: backup?.workspace.focusLog ?? [])
    }

    // MARK: - 日历

    /// 月视图的格子范围：当月第一天所在周的周一起，共 6 周
    static func calendarGrid(for month: Date) -> [String] {
        let cal = Day.cal
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let weekday = cal.component(.weekday, from: first)  // 1 = 周日
        let offset = (weekday + 5) % 7                       // 周一为 0
        let start = cal.date(byAdding: .day, value: -offset, to: first) ?? first
        return (0 ..< 42).map { Day.string(cal.date(byAdding: .day, value: $0, to: start) ?? start) }
    }

    /// 当前视图要读的日子：月 = 6 周格子，周 = 选中日所在的周，日 = 选中的一天；年视图不读数据
    func calendarVisibleDays() -> [String] {
        switch calendarMode {
        case .month: return Self.calendarGrid(for: calendarMonth)
        case .week: return Self.weekDays(of: calendarDay)
        case .day: return [calendarDay]
        case .year: return []
        }
    }

    /// 某天所在的周（周一到周日）
    static func weekDays(of day: String) -> [String] {
        guard let d = Day.parse(day) else { return [day] }
        let cal = Day.cal
        let offset = (cal.component(.weekday, from: d) + 5) % 7
        let start = cal.date(byAdding: .day, value: -offset, to: d) ?? d
        return (0 ..< 7).map { Day.string(cal.date(byAdding: .day, value: $0, to: start) ?? start) }
    }

    func setCalendarMode(_ mode: CalendarMode) {
        guard mode != calendarMode else { return }
        // 切视图时以选中的那天为中心
        if let d = Day.parse(calendarDay) { calendarMonth = d }
        calendarMode = mode
        Task { await loadCalendar(ifStale: true) }
    }

    /// 前进 / 后退一格：日 ±1 天，周 ±7 天，月 ±1 个月，年 ±1 年
    func stepCalendar(_ dir: Int) {
        let cal = Day.cal
        switch calendarMode {
        case .day, .week:
            let delta = calendarMode == .day ? dir : 7 * dir
            calendarDay = Day.add(calendarDay, days: delta)
            calPane.clear(); calendarDraft = nil
            calendarMonth = Day.parse(calendarDay) ?? calendarMonth
        case .month:
            calendarMonth = cal.date(byAdding: .month, value: dir, to: calendarMonth) ?? calendarMonth
        case .year:
            calendarMonth = cal.date(byAdding: .year, value: dir, to: calendarMonth) ?? calendarMonth
        }
        Task { await loadCalendar(ifStale: true) }
    }

    func calendarToday() {
        if calendarDay != Day.today() { calPane.clear(); calendarDraft = nil }
        calendarDay = Day.today()
        calendarMonth = Date()
        Task { await loadCalendar(ifStale: true) }
    }

    /// 在日历里选一天（可同时切到某个视图）
    func selectCalendarDay(_ day: String, mode: CalendarMode? = nil) {
        if day != calendarDay { calPane.clear(); calendarDraft = nil }
        calendarDay = day
        if let mode, mode != calendarMode {
            calendarMonth = Day.parse(day) ?? calendarMonth
            calendarMode = mode
            Task { await loadCalendar(ifStale: true) }
        } else if calendarMode == .week || calendarMode == .day {
            calendarMonth = Day.parse(day) ?? calendarMonth
            if calendarMode == .day { Task { await loadCalendar(ifStale: true) } }
        }
    }

    func loadCalendar(ifStale: Bool = false) async {
        guard hasDida || hasIdeashell else { return }
        let days = calendarVisibleDays()
        guard let from = days.first, let to = days.last else { return }
        // 已经读过的范围（比如整个月）盖住了现在要看的（某一周 / 某一天），而且还新，就不再请求
        if ifStale, let c = calendarCover, c.from <= from, c.to >= to, Date().timeIntervalSince(c.at) < 900 { return }
        guard beginLoad("calendar", ifStale: ifStale) else { return }
        defer { endLoad("calendar") }
        calendarLoading = true
        defer { calendarLoading = false }
        calendarError = nil

        if hasDida {
            do {
                let tasks = try await dida.tasksInRange(from, to)
                // 范围内的旧缓存换成新结果
                calendarTasks = calendarTasks.filter { pair in
                    guard let d = taskDay(pair.value) else { return true }
                    return d < from || d > to
                }
                for t in tasks { calendarTasks[t.id] = t }
            } catch {
                calendarError = "待办读取失败：" + error.localizedDescription
            }
        }
        if hasIdeashell {
            do {
                let start = Day.startOfDay(Day.parse(from) ?? Date())
                let end = Day.startOfDay(Day.parse(Day.add(to, days: 1)) ?? Date())
                let r = try await ideashell.notesInRange(start, end)
                var by: [String: [NoteInfo]] = [:]
                for n in r.notes.filter(isUserNote) { if let d = n.day { by[d, default: []].append(n) } }
                for d in days { calendarNotes[d] = by[d] ?? [] }
            } catch {
                calendarError = (calendarError.map { $0 + "；" } ?? "") + "笔记读取失败：" + error.localizedDescription
            }
        }
        if calendarError == nil {
            saveCalendarCache()
            // 和上次读的范围相连 / 重叠且还新，就合并成一个更大的范围
            if let c = calendarCover, Date().timeIntervalSince(c.at) < 900, c.to >= Day.add(from, days: -1), c.from <= Day.add(to, days: 1) {
                calendarCover = (min(c.from, from), max(c.to, to), c.at)
            } else {
                calendarCover = (from, to, Date())
            }
        }
    }

    /// 任务落在哪一天：有计划日按计划日，否则（已完成的无日期任务）按完成日
    func taskDay(_ t: DidaTask) -> String? {
        t.date ?? t.completedDate.map(Day.string)
    }

    func calendarTasks(on day: String) -> [DidaTask] {
        calendarTasks.values.filter { taskDay($0) == day }.sorted {
            if $0.done != $1.done { return !$0.done }
            let a = $0.time ?? "", b = $1.time ?? ""
            return a != b ? a < b : $0.priority > $1.priority
        }
    }

    // MARK: - 小工具

    func isFresh(_ name: String, key: String, within seconds: TimeInterval = 900) -> Bool {
        guard let s = loadStamps[name], s.key == key else { return false }
        return Date().timeIntervalSince(s.at) < seconds
    }

    func stamp(_ name: String, key: String) { loadStamps[name] = (key, Date()) }

    /// 我们自己改了数据（新建 / 完成 / 改期）后，回顾、洞察、日历的缓存作废，下次进页面重读
    func invalidateHistory() {
        historyDirty = false
        loadStamps.removeValue(forKey: "river")
        loadStamps.removeValue(forKey: "review")
        calendarCover = nil
    }

    /// 同一份数据正在读的时候，页面再要一次就不重复请求
    func beginLoad(_ name: String, ifStale: Bool) -> Bool {
        if inflight.contains(name) { return !ifStale }
        inflight.insert(name)
        return true
    }

    func endLoad(_ name: String) { inflight.remove(name) }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
