import {
  Action,
  ActionPanel,
  Alert,
  Color,
  confirmAlert,
  Form,
  Icon,
  List,
  LocalStorage,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import {
  Fragment,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { getNoteDetail } from "./api";
import { emptyFocus, formatMinutes } from "./dida-focus";
import {
  clearDida,
  describeSync,
  loadLastError,
  loadLastSync,
  syncAll,
  syncDida,
} from "./dida";
import { commentOnTask, didaTaskUrl } from "./dida-tasks";
import { DidaSetupForm } from "./dida-setup";
import { ago, daysBetween } from "./dossier";
import { NotesBrowser } from "./notes";
import {
  NextForm,
  ProgressForm,
  ReviewForm,
  TaskNoteForm,
} from "./project-forms";
import { InboxPage } from "./inbox-page";
import { ProjectPage } from "./project-page";
import { PendingOpen, takePendingOpen } from "./pending-open";
import {
  appendProgress,
  displayNote,
  milestoneText,
  recordMilestone,
  loadTaskNotes,
  noteUrl,
  TaskNoteRef,
} from "./task-notes";
import {
  byDateTime,
  isImportant,
  loadCachedTodoData,
  loadTodoData,
  quadrantOfRow,
  TodoData,
  TodoRow,
} from "./todo-data";
import {
  bumpPostpone,
  clearPostpone,
  loadPostpones,
  POSTPONE_WARN,
} from "./postpone";
import { QUADRANT_TITLE, Quadrant, projectOf } from "./todo-meta";
import { completeRow, createRow, patchRow, restoreRow } from "./todo-ops";
import { parseDateTimeFields, parseTodoInput } from "./todo-parse";
import { useWatchlist } from "./use-watchlist";
import { formatDate } from "./utils";
import { WatchAddForm, WatchLogForm } from "./watch-log";
import {
  removeWatch,
  setProjectStatus,
  setStaleDays,
  sparkline,
  STALE_CHOICES,
  STATUS_LABEL,
  STATUS_ORDER,
  WatchItem,
  WatchStats,
} from "./watchlist";

const WEEKDAYS = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
const VIEW_KEY = "todos-view-v1";
/** 在 macOS「快捷指令」里建一个同名快捷指令（动作：滴答清单 → 开始专注），即可一键开始 */
const FOCUS_SHORTCUT = "滴答开始专注";

const EMPTY_PROJECTS_MD = `# 项目

**待办**是短期要做的事，**项目**是长期在做的事（篆刻、读书、体重、某个人……）。

给项目起一个关键词，还可以再挂上若干**标签**，Todos 就会替你盯着它：

- 距上次提及已经多少天，太久没碰会标橙提醒
- 近 30 天提及次数、近 12 个月迷你图
- 你手写的「下一步」
- **项目主页**：要交付的成果（任务笔记）、相关任务、资料、最近提及

## 怎么添加

- 在这里按 \`⌘⇧P\`，填关键词，再从闪念贝壳已有标签里选几个
- 或在 Notes 的任意档案页按 \`⌘P\`，一键钉为项目
`;

type ViewMode = "time" | "quad";

function addDays(date: Date, days: number): string {
  const d = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  d.setDate(d.getDate() + days);
  return formatDate(d);
}

function dateLabel(date: string): string {
  const d = new Date(`${date}T00:00:00`);
  return Number.isNaN(d.getTime()) ? date : `${date} ${WEEKDAYS[d.getDay()]}`;
}

function clipText(raw: string, max = 1800): string {
  const text = displayNote(raw);
  return text.length > max
    ? `${text.slice(0, max).trimEnd()}\n\n…（后面的内容请打开笔记查看）`
    : text;
}

function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

type Block =
  | { kind: "todos"; key: string; title: string; items: TodoRow[] }
  | { kind: "projects" }
  | { kind: "dida" };

/** 按时间分组：逾期 / 今天 → 项目 → 明天 / 之后 / 最近已完成 */
function timeBlocks(open: TodoRow[], done: TodoRow[]): Block[] {
  const now = new Date();
  const today = formatDate(now);
  const tomorrow = addDays(now, 1);
  const sorted = [...open].sort(byDateTime);
  const blocks: Block[] = [];
  const push = (key: string, title: string, items: TodoRow[]) => {
    if (items.length > 0) blocks.push({ kind: "todos", key, title, items });
  };

  push(
    "overdue",
    "已逾期",
    sorted.filter((t) => t.date && t.date < today),
  );
  push(
    "today",
    `今天 · ${dateLabel(today)}`,
    sorted.filter((t) => t.date === today),
  );
  blocks.push({ kind: "projects" });
  push(
    "tomorrow",
    `明天 · ${dateLabel(tomorrow)}`,
    sorted.filter((t) => t.date === tomorrow),
  );
  const later = sorted.filter((t) => t.date && t.date > tomorrow);
  [...new Set(later.map((t) => t.date as string))].forEach((d) =>
    push(
      `d-${d}`,
      dateLabel(d),
      later.filter((t) => t.date === d),
    ),
  );
  push("done", "最近已完成", done);
  blocks.push({ kind: "dida" });
  return blocks;
}

/** 四象限：重要且紧急 / 重要不紧急 → 项目 → 紧急但不重要 / 不重要不紧急 */
function quadBlocks(open: TodoRow[], done: TodoRow[]): Block[] {
  const now = new Date();
  const sorted = [...open].sort(byDateTime);
  const of = (q: Quadrant) => sorted.filter((t) => quadrantOfRow(t, now) === q);
  const blocks: Block[] = [];
  const push = (q: Quadrant) => {
    const items = of(q);
    if (items.length > 0)
      blocks.push({ kind: "todos", key: q, title: QUADRANT_TITLE[q], items });
  };
  push("q1");
  push("q2");
  blocks.push({ kind: "projects" });
  push("q3");
  push("q4");
  if (done.length > 0)
    blocks.push({
      kind: "todos",
      key: "done",
      title: "最近已完成",
      items: done,
    });
  blocks.push({ kind: "dida" });
  return blocks;
}

const STATUS_COLOR: Record<WatchItem["status"], Color> = {
  active: Color.Blue,
  short: Color.Green,
  long: Color.Purple,
  paused: Color.SecondaryText,
};

function projectRows(
  items: WatchItem[],
  stats: Record<string, WatchStats>,
  today: string,
) {
  const rows = items.map((item, index) => {
    const s = stats[item.keyword];
    const gap = s?.lastDay ? daysBetween(s.lastDay, today) : null;
    const stale =
      item.status !== "paused" && gap !== null && gap >= item.staleDays;
    return { item, s, gap, stale, index };
  });
  // 该推进的排最前（越久没碰越靠前）→ 其余按状态（进行中 / 短期 / 长期）→ 搁置垫底
  const rank = (r: (typeof rows)[number]) =>
    r.stale ? 0 : r.item.status === "paused" ? 3 : 1;
  rows.sort(
    (a, b) =>
      rank(a) - rank(b) ||
      (a.stale && b.stale ? (b.gap ?? 0) - (a.gap ?? 0) : 0) ||
      STATUS_ORDER.indexOf(a.item.status) -
        STATUS_ORDER.indexOf(b.item.status) ||
      a.index - b.index,
  );
  return rows;
}

function projectDetail(
  item: WatchItem,
  s: WatchStats | undefined,
  gap: number | null,
  related: TodoRow[],
) {
  const todoLines = related
    .slice(0, 8)
    .map(
      (t) =>
        `- [ ] ${t.title}${t.date ? `（${t.date}${t.time ? ` ${t.time}` : ""}）` : ""}`,
    );
  const docRest = s?.doc.markdown.includes("\n## ")
    ? s.doc.markdown.slice(s.doc.markdown.indexOf("\n## ") + 1)
    : "";
  const md = [
    `# ${item.keyword}`,
    `**${STATUS_LABEL[item.status]}**${item.tags.length ? ` · ${item.tags.map((t) => `#${t}`).join(" ")}` : ""}${s?.lastDay ? ` · 最近一次提及：${s.lastDay}（${ago(gap ?? 0)}）` : ""}`,
    `## 下一步\n${item.next ? item.next : "_还没写下一步，按 ⌘E 设置_"}`,
    related.length > 0
      ? `## 近期任务（${related.length}）\n${todoLines.join("\n")}`
      : "",
    s ? docRest : "_统计中…_",
  ]
    .filter(Boolean)
    .join("\n\n");

  return (
    <List.Item.Detail
      markdown={md}
      metadata={
        s ? (
          <List.Item.Detail.Metadata>
            <List.Item.Detail.Metadata.Label
              title="近 30 天"
              text={`${s.count30} 次`}
            />
            <List.Item.Detail.Metadata.Label
              title="累计提及"
              text={`${s.total} 次`}
            />
            <List.Item.Detail.Metadata.Label
              title="近 12 个月"
              text={s.total > 0 ? sparkline(s.series) : "—"}
            />
            <List.Item.Detail.Metadata.Label
              title="没碰提醒"
              text={`${item.staleDays} 天`}
            />
          </List.Item.Detail.Metadata>
        ) : undefined
      }
    />
  );
}

export default function Command() {
  const [data, setData] = useState<TodoData>({
    open: [],
    inbox: [],
    done: [],
    connected: false,
    ideaOpen: [],
    ideaDone: [],
    focus: emptyFocus(),
  });
  const [isLoading, setIsLoading] = useState(true);
  const [searchText, setSearchText] = useState("");
  const [view, setView] = useState<ViewMode>("time");
  const [tick, setTick] = useState(0);
  const [syncing, setSyncing] = useState(false);
  const [lastSync, setLastSync] = useState(0);
  const [lastError, setLastError] = useState("");
  const [taskNotes, setTaskNotes] = useState<Record<string, TaskNoteRef>>({});
  const [noteTexts, setNoteTexts] = useState<Record<string, string>>({});
  const [postpones, setPostpones] = useState<Record<string, number>>({});
  const syncingRef = useRef(false);
  /** 最新数据是否已经到了（到了以后就不再用缓存覆盖） */
  const freshRef = useRef(false);
  /** 菜单栏点进来时要直接打开的页面（记一条 / 项目主页 / 新增项目） */
  const [pendingOpen, setPendingOpenState] = useState<
    PendingOpen | undefined
  >();
  const [dataReady, setDataReady] = useState(false);
  const { push } = useNavigation();

  const { items: projects, stats, computing } = useWatchlist(true, tick);
  const connected = data.connected;

  useEffect(() => {
    LocalStorage.getItem<string>(VIEW_KEY).then(
      (v) => v === "quad" && setView("quad"),
    );
  }, []);

  const runSync = useCallback(async (d: TodoData, manual: boolean) => {
    if (syncingRef.current) return false;
    syncingRef.current = true;
    setSyncing(true);
    let changed = false;
    try {
      const r = manual
        ? await syncAll()
        : await syncDida(d.ideaOpen, d.ideaDone);
      setLastSync(await loadLastSync());
      setLastError(await loadLastError());
      changed = r.completedFromDida > 0 || r.created > 0;
      if (manual || r.authError || r.failed > 0 || r.completedFromDida > 0) {
        await showToast({
          style:
            r.authError || r.failed > 0
              ? Toast.Style.Failure
              : Toast.Style.Success,
          title: r.authError ? "滴答清单同步失败" : "滴答清单已同步",
          message: describeSync(r),
        });
      }
    } catch (e) {
      await showToast({
        style: Toast.Style.Failure,
        title: "滴答清单同步失败",
        message: errorMessage(e),
      });
    } finally {
      syncingRef.current = false;
      setSyncing(false);
    }
    return changed;
  }, []);

  const reload = useCallback(
    async (sync = true) => {
      setIsLoading(true);
      try {
        const d = await loadTodoData();
        freshRef.current = true;
        setData(d);
        setDataReady(true);
        const [sync, err, notes, posts] = await Promise.all([
          loadLastSync(),
          loadLastError(),
          loadTaskNotes(),
          loadPostpones(),
        ]);
        setLastSync(sync);
        setLastError(err);
        setTaskNotes(notes);
        setPostpones(posts);
        // 任务笔记的正文在后台读取（最多 8 条未完成任务），读到后显示在右侧
        d.open
          .filter((r) => notes[r.key])
          .slice(0, 8)
          .forEach((r) => {
            const id = notes[r.key].noteId;
            getNoteDetail(id)
              .then((n) =>
                setNoteTexts((prev) => ({
                  ...prev,
                  [id]: (n.content ?? n.body ?? "").trim(),
                })),
              )
              .catch(() => undefined);
          });
        setIsLoading(false);
        if (sync && d.connected) {
          // 后台把闪念贝壳里带日期的待办推到滴答；有变化再静默刷新一次
          runSync(d, false).then((changed) => {
            if (changed) reload(false);
          });
        }
      } catch (e) {
        await showToast({
          style: Toast.Style.Failure,
          title: "加载待办失败",
          message: errorMessage(e),
        });
      } finally {
        setIsLoading(false);
      }
    },
    [runSync],
  );

  useEffect(() => {
    takePendingOpen()
      .then(setPendingOpenState)
      .catch(() => undefined);
  }, []);

  useEffect(() => {
    if (!pendingOpen) return;
    if (pendingOpen.action === "add") {
      setPendingOpenState(undefined);
      push(<WatchAddForm />);
      return;
    }
    // 项目主页要用到任务和统计，等数据（缓存或最新）到了再打开
    if (projects.length === 0 || (pendingOpen.action === "page" && !dataReady))
      return;
    setPendingOpenState(undefined);
    const key = (pendingOpen.keyword ?? "").trim().toLowerCase();
    const item = projects.find((x) => x.keyword.trim().toLowerCase() === key);
    if (!item) return;
    if (pendingOpen.action === "log") {
      push(<WatchLogForm keyword={item.keyword} tags={item.tags} />);
    } else {
      const related = data.open
        .filter((r) => projectOf(r.title, [item], r.tags))
        .sort(byDateTime);
      push(
        <ProjectPage
          item={item}
          stats={stats[item.keyword]}
          rows={related}
          focus={data.focus}
          onChanged={() => setTick((t) => t)}
        />,
      );
    }
  }, [pendingOpen, projects, dataReady, data, stats, push]);

  useEffect(() => {
    reload();
    // 同时读上次的缓存：先把列表秒出来，最新数据到了再替换（不用干等滴答接口）
    (async () => {
      const [cached, notes, posts] = await Promise.all([
        loadCachedTodoData(),
        loadTaskNotes(),
        loadPostpones(),
      ]);
      if (!cached || freshRef.current) return;
      setData(cached);
      setDataReady(true);
      setTaskNotes((prev) => (Object.keys(prev).length ? prev : notes));
      setPostpones((prev) => (Object.keys(prev).length ? prev : posts));
    })().catch(() => undefined);
  }, [reload]);

  async function act(title: string, ok: string, fn: () => Promise<void>) {
    const toast = await showToast({ style: Toast.Style.Animated, title });
    try {
      await fn();
      toast.style = Toast.Style.Success;
      toast.title = ok;
      await reload();
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = "操作失败";
      toast.message = errorMessage(e);
    }
  }

  const toggle = (row: TodoRow) =>
    row.done
      ? act("恢复为未完成...", "已恢复为未完成", () => restoreRow(row))
      : act("标记完成...", "已完成", async () => {
          await completeRow(row);
          await clearPostpone(row.key);
          // 属于某个项目：自动在项目主页「里程碑与进展」记一行
          const p = projectOf(row.title, projects, row.tags);
          if (p)
            await recordMilestone(
              p.keyword,
              milestoneText(row.title, taskNotes[row.key]),
            ).catch(() => undefined);
        });

  async function createFromSearch() {
    const text = searchText.trim();
    if (!text) return;
    const { content, date, time } = parseTodoInput(text);
    const important = /[!！]重要/.test(content);
    const title =
      content.replace(/\s*[!！](?:重要|紧急)/g, "").trim() || content;
    await act("正在创建待办...", `已添加：${title}`, async () => {
      await createRow({ title, date, time, priority: important ? 5 : 0 });
      setSearchText("");
    });
  }

  async function switchView(next: ViewMode) {
    setView(next);
    await LocalStorage.setItem(VIEW_KEY, next);
  }

  async function disconnectDida() {
    if (
      await confirmAlert({
        title: "断开滴答清单？",
        message:
          "已同步到滴答的任务不会被删除；之后 Todos 回到只显示闪念贝壳的待办。",
        primaryAction: { title: "断开", style: Alert.ActionStyle.Destructive },
      })
    ) {
      await clearDida();
      await showToast({ style: Toast.Style.Success, title: "已断开滴答清单" });
      await reload(false);
    }
  }

  const now = new Date();
  const today = formatDate(now);
  const blocks = useMemo(
    () =>
      view === "quad"
        ? quadBlocks(data.open, data.done)
        : timeBlocks(data.open, data.done),
    [view, data],
  );
  const projRows = useMemo(
    () => projectRows(projects, stats, today),
    [projects, stats, today],
  );

  const refresh = () => {
    setTick((t) => t + 1);
    reload();
  };

  // ── 通用 Actions ──
  const didaActions = connected ? (
    <Action
      title="立即同步滴答清单"
      icon={Icon.ArrowClockwise}
      shortcut={{ modifiers: ["cmd", "shift"], key: "s" }}
      onAction={() =>
        runSync(data, true).then((c) => void (c && reload(false)))
      }
    />
  ) : (
    <Action.Push
      title="连接滴答清单"
      icon={Icon.Link}
      shortcut={{ modifiers: ["cmd", "shift"], key: "s" }}
      target={<DidaSetupForm onDone={() => reload()} />}
    />
  );

  const inboxAction = (
    <Action.Push
      title="整理收集箱（没有日期的任务）"
      icon={Icon.Tray}
      shortcut={{ modifiers: ["cmd", "shift"], key: "i" }}
      target={
        <InboxPage
          rows={data.inbox}
          projects={projects}
          onChanged={() => reload(false)}
        />
      }
    />
  );

  const commonActions = (
    <>
      {searchText.trim() && (
        <Action
          title={`用「${searchText.trim().slice(0, 16)}」创建待办`}
          icon={Icon.Plus}
          shortcut={{ modifiers: ["cmd"], key: "return" }}
          onAction={createFromSearch}
        />
      )}
      <Action.Push
        title="新建待办"
        icon={Icon.PlusCircle}
        shortcut={{ modifiers: ["cmd"], key: "n" }}
        target={
          <TodoForm
            projects={projects}
            connected={connected}
            onDone={() => reload()}
          />
        }
      />
      <Action.Push
        title="新增项目"
        icon={Icon.Pin}
        shortcut={{ modifiers: ["cmd", "shift"], key: "p" }}
        target={<WatchAddForm />}
      />
      <Action
        title={view === "quad" ? "切换到时间视图" : "切换到四象限视图"}
        icon={view === "quad" ? Icon.Calendar : Icon.AppWindowGrid2x2}
        shortcut={{ modifiers: ["cmd"], key: "q" }}
        onAction={() => switchView(view === "quad" ? "time" : "quad")}
      />
      {inboxAction}
      {didaActions}
      <Action
        title="刷新"
        icon={Icon.ArrowClockwise}
        shortcut={{ modifiers: ["cmd"], key: "r" }}
        onAction={refresh}
      />
    </>
  );

  // ── 待办行 ──
  const renderRow = (row: TodoRow, groupKey: string) => {
    const isOverdue = !row.done && !!row.date && row.date < today;
    const important = isImportant(row);
    const project = projectOf(row.title, projects, row.tags);
    const note = taskNotes[row.key];
    const noteText = note ? noteTexts[note.noteId] : undefined;
    const postponed = postpones[row.key] ?? 0;
    const focus = row.source === "dida" ? data.focus.byTask[row.id] : undefined;
    const quadrant = quadrantOfRow(row, now);
    // 只在已逾期 / 已完成分组里带上日期（其余分组标题已含日期）；不放项目名 / 清单名，避免挤占标题
    // 标签要短，列表左栏很窄：普通分组只显示时间；已逾期 / 已完成显示 MM-DD（已完成且是今天则显示时间）
    const showDate =
      !!row.date &&
      (groupKey === "overdue" || (groupKey === "done" && row.date !== today));
    const timeTag = showDate ? (row.date as string).slice(5) : (row.time ?? "");
    return (
      <List.Item
        key={row.key}
        id={`todo-${row.key}`}
        title={row.title}
        subtitle={note && !row.done ? `→ ${note.deliverable}` : undefined}
        keywords={[
          ...(project ? [project.keyword] : []),
          ...(row.listName ? [row.listName] : []),
        ]}
        icon={
          row.done
            ? { source: Icon.CheckCircle, tintColor: Color.Green }
            : {
                source: Icon.Circle,
                tintColor: isOverdue
                  ? Color.Red
                  : important
                    ? Color.Orange
                    : Color.SecondaryText,
              }
        }
        accessories={[
          ...(important
            ? [
                {
                  icon: { source: Icon.Star, tintColor: Color.Orange },
                  tooltip: "重要",
                },
              ]
            : []),
          ...(row.urgentMark
            ? [
                {
                  icon: { source: Icon.ExclamationMark, tintColor: Color.Red },
                  tooltip: "紧急",
                },
              ]
            : []),
          ...(!row.done && postponed >= POSTPONE_WARN
            ? [
                {
                  icon: { source: Icon.Repeat, tintColor: Color.Orange },
                  tooltip: `已推迟 ${postponed} 次`,
                },
              ]
            : []),
          ...(note
            ? [
                {
                  icon: Icon.Document,
                  tooltip: `任务笔记：${note.deliverable}`,
                },
              ]
            : row.done
              ? []
              : [
                  {
                    icon: {
                      source: Icon.QuestionMark,
                      tintColor: Color.SecondaryText,
                    },
                    tooltip: "还没想清楚要交付什么：按 ⌘J 创建任务笔记",
                  },
                ]),
          ...(timeTag
            ? [
                {
                  tag: {
                    value: timeTag,
                    color: isOverdue ? Color.Red : Color.Blue,
                  },
                },
              ]
            : []),
        ]}
        detail={
          <List.Item.Detail
            markdown={[
              `# ${row.title}`,
              !row.done && postponed >= POSTPONE_WARN
                ? `**已推迟 ${postponed} 次**：这个任务可能太大，或目的还不清楚。试着拆成更小的、能交付的成果，并按 \`⌘J\` 补写任务笔记。`
                : "",
              note
                ? `**交付成果**：${note.deliverable}`
                : row.done
                  ? ""
                  : "_还没有任务笔记。先想清楚这个任务要**交付什么成果**，按 `⌘J` 创建任务笔记。_",
              note
                ? noteText === undefined
                  ? "_正在读取任务笔记…_"
                  : clipText(noteText)
                : "",
              project?.next
                ? `**「${project.keyword}」的下一步**：${project.next}`
                : "",
            ]
              .filter(Boolean)
              .join("\n\n")}
            metadata={
              <List.Item.Detail.Metadata>
                <List.Item.Detail.Metadata.Label
                  title="日期"
                  text={row.date ? dateLabel(row.date) : "无"}
                />
                <List.Item.Detail.Metadata.Label
                  title="时间"
                  text={row.time ?? "无"}
                />
                <List.Item.Detail.Metadata.Label
                  title="象限"
                  text={QUADRANT_TITLE[quadrant]}
                />
                <List.Item.Detail.Metadata.Label
                  title="项目"
                  text={project ? project.keyword : "无"}
                />
                {focus && (
                  <List.Item.Detail.Metadata.Label
                    title="专注"
                    text={`今日 ${formatMinutes(focus.todayMin)} · 近 7 天 ${formatMinutes(focus.weekMin)}`}
                  />
                )}
                <List.Item.Detail.Metadata.Label
                  title="来源"
                  text={
                    row.source === "dida"
                      ? `滴答清单${row.listName ? ` · ${row.listName}` : ""}`
                      : connected && row.date
                        ? "闪念贝壳（待同步到滴答）"
                        : "闪念贝壳"
                  }
                />
              </List.Item.Detail.Metadata>
            }
          />
        }
        actions={
          <ActionPanel>
            <Action
              title={row.done ? "恢复为未完成" : "标记完成"}
              icon={row.done ? Icon.Circle : Icon.CheckCircle}
              onAction={() => toggle(row)}
            />
            {!row.done && (
              <Action.OpenInBrowser
                title={`开始专注（快捷指令「${FOCUS_SHORTCUT}」）`}
                icon={Icon.Clock}
                url={`shortcuts://run-shortcut?name=${encodeURIComponent(FOCUS_SHORTCUT)}&input=text&text=${encodeURIComponent(row.title)}`}
                shortcut={{ modifiers: ["cmd"], key: "p" }}
              />
            )}
            {!row.done && (
              <Action.Push
                title="完成并写复盘"
                icon={Icon.Pencil}
                shortcut={{ modifiers: ["cmd", "shift"], key: "return" }}
                target={
                  <ReviewForm
                    row={row}
                    project={project?.keyword}
                    noteId={note?.noteId}
                  />
                }
              />
            )}
            {!row.done &&
              (note ? (
                <>
                  <Action.OpenInBrowser
                    title="打开任务笔记"
                    url={noteUrl(note.noteId)}
                    shortcut={{ modifiers: ["cmd"], key: "j" }}
                  />
                  <Action.Push
                    title="记一条进展（写入任务笔记）"
                    icon={Icon.Pencil}
                    shortcut={{ modifiers: ["cmd"], key: "l" }}
                    target={
                      <ProgressForm
                        noteId={note.noteId}
                        title={row.title}
                        taskKey={row.key}
                        projectId={row.projectId}
                      />
                    }
                  />
                </>
              ) : (
                <Action.Push
                  title="创建任务笔记"
                  icon={Icon.Document}
                  shortcut={{ modifiers: ["cmd"], key: "j" }}
                  target={
                    <TaskNoteForm
                      row={row}
                      project={project?.keyword}
                      onDone={() => reload(false)}
                    />
                  }
                />
              ))}
            <Action.Push
              title="编辑待办"
              icon={Icon.Pencil}
              shortcut={{ modifiers: ["cmd"], key: "e" }}
              target={
                <TodoForm
                  row={row}
                  projects={projects}
                  connected={connected}
                  onDone={() => reload()}
                />
              }
            />
            {!row.done && (
              <>
                <Action
                  title={important ? "取消「重要」" : "标记为重要"}
                  icon={Icon.Star}
                  shortcut={{ modifiers: ["cmd"], key: "i" }}
                  onAction={() =>
                    act("正在保存...", "已更新", () =>
                      patchRow(row, { priority: important ? 0 : 5 }),
                    )
                  }
                />
                <Action
                  title="推迟到明天"
                  icon={Icon.ArrowRight}
                  shortcut={{ modifiers: ["cmd", "shift"], key: "t" }}
                  onAction={() =>
                    act("正在保存...", "已推迟到明天", async () => {
                      await patchRow(row, { date: addDays(now, 1) });
                      if (!row.date || row.date < addDays(now, 1))
                        await bumpPostpone(row.key);
                    })
                  }
                />
              </>
            )}
            {row.source === "dida" && !row.done && (
              <>
                {note && focus && focus.todayMin > 0 && (
                  <Action
                    title="把今日专注记入任务笔记"
                    icon={Icon.Pencil}
                    shortcut={{ modifiers: ["cmd", "opt"], key: "l" }}
                    onAction={() =>
                      act("正在写入任务笔记...", "已记入进展记录", async () => {
                        const text = `专注 ${formatMinutes(focus.todayMin)}${focus.todayCount > 1 ? `（${focus.todayCount} 段）` : ""}`;
                        await appendProgress(note.noteId, text);
                        await commentOnTask(
                          row.key,
                          `进展：${text}`,
                          row.projectId,
                        );
                      })
                    }
                  />
                )}
              </>
            )}
            {row.source === "dida" && (
              <Action.OpenInBrowser
                title="在滴答清单中打开"
                url={didaTaskUrl(row)}
                shortcut={{ modifiers: ["cmd"], key: "o" }}
              />
            )}
            {commonActions}
            <Action.CopyToClipboard
              title="复制内容"
              content={row.title}
              shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
            />
          </ActionPanel>
        }
      />
    );
  };

  // ── 项目分区 ──
  const renderProjects = () => {
    if (projRows.length === 0) {
      return (
        <List.Section title="项目">
          <List.Item
            id="proj-empty"
            title="还没有项目"
            subtitle="钉住长期在做的事：篆刻、读书、体重…"
            icon={{ source: Icon.Pin, tintColor: Color.SecondaryText }}
            detail={<List.Item.Detail markdown={EMPTY_PROJECTS_MD} />}
            actions={
              <ActionPanel>
                <Action.Push
                  title="新增项目"
                  icon={Icon.Pin}
                  target={<WatchAddForm />}
                />
                {commonActions}
              </ActionPanel>
            }
          />
        </List.Section>
      );
    }

    return (
      <List.Section
        title="项目"
        subtitle={`${projRows.length}${computing ? " · 统计中…" : ""}`}
      >
        {projRows.map(({ item, s, gap, stale }) => {
          const related = data.open
            .filter((r) => projectOf(r.title, [item], r.tags))
            .sort(byDateTime);
          return (
            <List.Item
              key={`proj-${item.keyword}`}
              id={`proj-${item.keyword}`}
              title={item.keyword}
              subtitle={
                item.next
                  ? `→ ${item.next}`
                  : !s
                    ? "统计中…"
                    : s.lastDay
                      ? `${ago(gap ?? 0)} · 近 30 天 ${s.count30} 次`
                      : "还没有记录"
              }
              icon={{
                source: Icon.Pin,
                tintColor: stale ? Color.Orange : STATUS_COLOR[item.status],
              }}
              accessories={[
                ...(stale
                  ? [{ tag: { value: `${gap} 天没碰了`, color: Color.Orange } }]
                  : []),
                ...(related.length > 0
                  ? [{ text: `${related.length} 任务` }]
                  : []),
                ...(item.status !== "active"
                  ? [{ text: STATUS_LABEL[item.status] }]
                  : []),
                ...(s && s.total > 0 ? [{ text: sparkline(s.series) }] : []),
              ]}
              detail={projectDetail(item, s, gap, related)}
              actions={
                <ActionPanel>
                  <Action.Push
                    title="打开项目主页"
                    icon={Icon.House}
                    target={
                      <ProjectPage
                        item={item}
                        stats={s}
                        rows={related}
                        focus={data.focus}
                        onChanged={() => setTick((t) => t)}
                      />
                    }
                  />
                  <Action.Push
                    title={`新建待办「${item.keyword}」`}
                    icon={Icon.PlusCircle}
                    target={
                      <TodoForm
                        project={item.keyword}
                        projects={projects}
                        connected={connected}
                        onDone={() => reload()}
                      />
                    }
                  />
                  <Action.Push
                    title={`记一条「${item.keyword}」`}
                    icon={Icon.Pencil}
                    shortcut={{ modifiers: ["cmd"], key: "l" }}
                    target={
                      <WatchLogForm keyword={item.keyword} tags={item.tags} />
                    }
                  />
                  <Action.Push
                    title="设置下一步"
                    icon={Icon.Flag}
                    shortcut={{ modifiers: ["cmd"], key: "e" }}
                    target={
                      <NextForm
                        keyword={item.keyword}
                        current={item.next}
                        onDone={() => undefined}
                      />
                    }
                  />
                  <Action.Push
                    title="编辑标签"
                    icon={Icon.Tag}
                    shortcut={{ modifiers: ["cmd"], key: "t" }}
                    target={<WatchAddForm edit={item} />}
                  />
                  <Action.Push
                    title="查看档案"
                    icon={Icon.Person}
                    shortcut={{ modifiers: ["cmd"], key: "d" }}
                    target={<NotesBrowser dossierOf={item.keyword} />}
                  />
                  {s && (
                    <Action.CopyToClipboard
                      title="复制简报（Markdown）"
                      icon={Icon.Clipboard}
                      content={s.doc.copy}
                      shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
                    />
                  )}
                  <ActionPanel.Submenu
                    title={`状态（当前：${STATUS_LABEL[item.status]}）`}
                    icon={Icon.Tag}
                  >
                    {STATUS_ORDER.map((st) => (
                      <Action
                        key={st}
                        title={`${STATUS_LABEL[st]}${st === item.status ? "（当前）" : ""}`}
                        onAction={async () => {
                          await setProjectStatus(item.keyword, st);
                          await showToast({
                            style: Toast.Style.Success,
                            title: `「${item.keyword}」已设为${STATUS_LABEL[st]}`,
                            message:
                              st === "paused" ? "搁置后不再提醒" : undefined,
                          });
                        }}
                      />
                    ))}
                  </ActionPanel.Submenu>
                  <ActionPanel.Submenu
                    title={`提醒：超过几天没碰（当前 ${item.staleDays} 天）`}
                    icon={Icon.Bell}
                  >
                    {STALE_CHOICES.map((d) => (
                      <Action
                        key={d}
                        title={`${d} 天${d === item.staleDays ? "（当前）" : ""}`}
                        onAction={async () => {
                          await setStaleDays(item.keyword, d);
                          await showToast({
                            style: Toast.Style.Success,
                            title: `「${item.keyword}」超过 ${d} 天没提及会提醒`,
                          });
                        }}
                      />
                    ))}
                  </ActionPanel.Submenu>
                  <Action
                    title="移除项目"
                    icon={Icon.XMarkCircle}
                    style={Action.Style.Destructive}
                    shortcut={{ modifiers: ["ctrl"], key: "x" }}
                    onAction={async () => {
                      await removeWatch(item.keyword);
                      await showToast({
                        style: Toast.Style.Success,
                        title: `已移除项目「${item.keyword}」`,
                      });
                    }}
                  />
                  {commonActions}
                </ActionPanel>
              }
            />
          );
        })}
      </List.Section>
    );
  };

  // ── 滴答清单状态行 ──
  const problem = [data.warning, lastError].filter(Boolean).join("\n\n");
  const focusTitles = (id: string) =>
    data.focus.titles[id] ??
    [...data.open, ...data.done].find((r) => r.id === id)?.title ??
    "（其他任务）";
  const focusLines = Object.entries(data.focus.byTask)
    .sort((a, b) => b[1].weekMin - a[1].weekMin)
    .slice(0, 10)
    .map(
      ([id, f]) =>
        `- ${focusTitles(id)}：今日 ${formatMinutes(f.todayMin)}，近 7 天 ${formatMinutes(f.weekMin)}`,
    );
  const focusMd = `# 专注\n\n**今日**：${formatMinutes(data.focus.todayMin)}（${data.focus.todayPomos} 个番茄）\n\n**近 7 天**：${formatMinutes(data.focus.weekMin)}（${data.focus.weekPomos} 个番茄）\n\n${
    focusLines.length
      ? `## 按任务\n\n${focusLines.join("\n")}`
      : "还没有关联到任务的专注记录。"
  }\n\n计时在滴答里进行：任务上按 \`⌘P\` 通过快捷指令开始专注。`;
  const inboxMd = `# 整理收集箱

没有日期的任务不会出现在列表里。在这里逐条处理：

- **定日期**：安排后会出现在对应的分组
- **归入项目**：给任务打上项目标签
- **写交付成果**：创建任务笔记
- **完成** / **删除**

当前有 **${data.inbox.length}** 条没有日期的任务。`;
  const renderDida = () => (
    <List.Section title="滴答清单">
      <List.Item
        id="inbox"
        title="整理收集箱"
        subtitle={`${data.inbox.length} 条没有日期`}
        icon={{
          source: Icon.Tray,
          tintColor: data.inbox.length > 0 ? Color.Orange : Color.SecondaryText,
        }}
        detail={<List.Item.Detail markdown={inboxMd} />}
        actions={
          <ActionPanel>
            {inboxAction}
            {commonActions}
          </ActionPanel>
        }
      />
      {connected && (
        <List.Item
          id="dida-focus"
          title="专注"
          subtitle={`今日 ${formatMinutes(data.focus.todayMin)} · 近 7 天 ${formatMinutes(data.focus.weekMin)}`}
          icon={{ source: Icon.Clock, tintColor: Color.Red }}
          detail={<List.Item.Detail markdown={focusMd} />}
          actions={
            <ActionPanel>
              <Action
                title="刷新"
                icon={Icon.ArrowClockwise}
                onAction={refresh}
              />
              {commonActions}
            </ActionPanel>
          }
        />
      )}
      <List.Item
        id="dida-status"
        title={connected ? "已连接滴答清单" : "连接滴答清单"}
        subtitle={
          connected
            ? syncing
              ? "同步中…"
              : problem
                ? "有问题，查看右侧"
                : lastSync
                  ? `上次同步 ${new Date(lastSync).toTimeString().slice(0, 5)}`
                  : "尚未同步"
            : "让滴答成为提醒的核心"
        }
        icon={{
          source: Icon.Bell,
          tintColor: connected
            ? problem
              ? Color.Orange
              : Color.Green
            : Color.SecondaryText,
        }}
        detail={
          <List.Item.Detail
            markdown={
              connected
                ? `# 滴答清单\n\n已连接。这里的待办**以滴答清单为核心**：逾期、今天、近 7 天的任务都从滴答拉取，完成 / 改期 / 改优先级会直接改滴答；闪念贝壳里带日期的待办会自动同步过去并提醒。\n\n- 有时间：准点提醒；只有日期：当天 9:00 提醒\n- 没有日期的任务不显示在列表里，在「整理收集箱」里处理（\`⌘⇧I\`）\n- 闪念贝壳没有删除接口，所以**删除不会同步**\n\n\`⌘⇧S\` 立即同步。${problem ? `\n\n**最近的问题**：\n\n${problem}` : ""}`
                : "# 连接滴答清单\n\n连接后，Todos 会以滴答清单为核心：今天、近 7 天的任务从滴答拉取并由滴答提醒你；闪念贝壳的笔记作为任务的支撑（任务笔记 / 项目主页）。\n\n需要网页版滴答清单里的 **API 口令**：头像 → 设置 → 账户与安全 → API 口令 → 创建并复制。按回车开始连接。"
            }
          />
        }
        actions={
          <ActionPanel>
            {connected ? (
              <>
                <Action
                  title="立即同步"
                  icon={Icon.ArrowClockwise}
                  onAction={() =>
                    runSync(data, true).then((c) => void (c && reload(false)))
                  }
                />
                <Action.Push
                  title="重新连接"
                  icon={Icon.Link}
                  target={<DidaSetupForm onDone={() => reload()} />}
                />
                <Action
                  title="断开滴答清单"
                  icon={Icon.XMarkCircle}
                  onAction={disconnectDida}
                />
              </>
            ) : (
              <Action.Push
                title="连接滴答清单"
                icon={Icon.Link}
                target={<DidaSetupForm onDone={() => reload()} />}
              />
            )}
            {commonActions}
          </ActionPanel>
        }
      />
    </List.Section>
  );

  return (
    <List
      isLoading={isLoading}
      isShowingDetail
      searchBarPlaceholder="搜索待办 / 项目；输入「明天 15:00 开会 !重要」后 ⌘↵ 直接创建"
      onSearchTextChange={setSearchText}
    >
      {blocks.map((b) => {
        if (b.kind === "projects")
          return <Fragment key="projects">{renderProjects()}</Fragment>;
        if (b.kind === "dida")
          return <Fragment key="dida">{renderDida()}</Fragment>;
        return (
          <List.Section
            key={b.key}
            title={b.title}
            subtitle={`${b.items.length}`}
          >
            {b.items.map((t) => renderRow(t, b.key))}
          </List.Section>
        );
      })}
      {/* 仅在没有可见条目时才会显示 */}
      {!isLoading && (
        <List.EmptyView
          title={searchText.trim() ? "没有匹配的待办或项目" : "没有待办"}
          description={
            searchText.trim()
              ? "按 ⌘↵ 用输入的文字直接创建待办（可含日期时间）"
              : "在搜索栏输入内容后按 ⌘↵ 创建，或按 ⌘N 新建"
          }
          icon={Icon.CheckCircle}
          actions={<ActionPanel>{commonActions}</ActionPanel>}
        />
      )}
    </List>
  );
}

function TodoForm({
  row,
  project,
  projects,
  connected,
  onDone,
}: {
  row?: TodoRow;
  project?: string;
  projects: WatchItem[];
  connected: boolean;
  onDone: () => Promise<void> | void;
}) {
  const { pop } = useNavigation();
  const editing = !!row;
  const [chosen, setChosen] = useState(project ?? "");

  async function handleSubmit(values: {
    content: string;
    date: string;
    time: string;
    important: boolean;
  }) {
    const title = values.content.trim();
    if (!title) {
      await showToast({ style: Toast.Style.Failure, title: "请输入待办内容" });
      return;
    }
    const when = parseDateTimeFields(values.date, values.time);
    if (!when.ok) {
      await showToast({
        style: Toast.Style.Failure,
        title: "无法识别日期或时间",
        message: "日期例：2026-10-09、明天、周五；时间例：15:30、下午3点",
      });
      return;
    }

    const toast = await showToast({
      style: Toast.Style.Animated,
      title: editing ? "正在保存..." : "正在创建...",
    });
    try {
      if (row) {
        if (when.date && row.date && when.date > row.date)
          await bumpPostpone(row.key);
        await patchRow(row, {
          ...(title !== row.title ? { title } : {}),
          ...(when.date && when.date !== row.date ? { date: when.date } : {}),
          ...(when.time && when.time !== row.time ? { time: when.time } : {}),
          ...(values.important !== row.priority >= 3
            ? { priority: values.important ? 5 : 0 }
            : {}),
        });
      } else {
        // 归属项目：滴答任务打上项目标签；闪念贝壳待办在文字末尾补 #项目
        const asTag = chosen && connected;
        const text =
          chosen &&
          !connected &&
          !title.toLowerCase().includes(chosen.toLowerCase())
            ? `${title} #${chosen}`
            : title;
        await createRow({
          title: text,
          date: when.date,
          time: when.time,
          priority: values.important ? 5 : 0,
          tags: asTag ? [chosen] : undefined,
        });
      }
      toast.style = Toast.Style.Success;
      toast.title = editing ? "已保存" : "已创建";
      await onDone();
      pop();
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = editing ? "保存失败" : "创建失败";
      toast.message = errorMessage(e);
    }
  }

  return (
    <Form
      navigationTitle={
        editing ? "编辑待办" : project ? `新建待办 · ${project}` : "新建待办"
      }
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title={editing ? "保存" : "创建"}
            onSubmit={handleSubmit}
          />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="content"
        title="内容"
        placeholder="要做什么？"
        defaultValue={row?.title ?? ""}
      />
      {projects.length > 0 && !editing && (
        <Form.TextField
          id="project"
          title="归属项目"
          placeholder={`可选，如：${projects[0].keyword}`}
          value={chosen}
          onChange={setChosen}
          info="填项目关键词：滴答任务会打上同名标签，之后在项目里就能看到它"
        />
      )}
      <Form.TextField
        id="date"
        title="日期"
        placeholder="如 2026-10-09 / 明天 / 周五 / 10月9日"
        defaultValue={row?.date ?? ""}
        info={
          editing
            ? "留空表示保持不变"
            : "留空表示无日期（无日期的任务不会显示在这里）"
        }
      />
      <Form.TextField
        id="time"
        title="时间"
        placeholder="如 15:30 / 下午3点半"
        defaultValue={row?.time ?? ""}
        info={
          editing
            ? "留空表示保持不变"
            : "留空表示全天；有时间则准点提醒，仅日期则当天 9:00 提醒"
        }
      />
      <Form.Checkbox
        id="important"
        label="重要（高优先级）"
        defaultValue={(row?.priority ?? 0) >= 3}
      />
    </Form>
  );
}
