import {
  Action,
  ActionPanel,
  Color,
  Icon,
  LaunchProps,
  List,
  showToast,
  Toast,
} from "@raycast/api";
import { useEffect, useMemo, useRef, useState } from "react";
import { getNoteId, NoteInfo, searchNotes, TodoItem, updateTodos } from "./api";
import { extractDate, listDailyNotes } from "./daily";
import { DetailDoc } from "./detail-doc";
import { DossierData, DossierNote, loadDossier } from "./dossier";
import { NoteDetailView } from "./note-detail-view";
import { TODOS_LIST_QUERY } from "./entry-flags";
import TodosList from "./todos-list";
import { loadMemory, MemoryData, pickRandom, sameDayIds } from "./memory-lane";
import { buildDayOverview, buildRangeOverview, findDay } from "./overview";
import {
  loadTimeline,
  localHHmm,
  sliceDay,
  TimelineData,
} from "./timeline-data";
import { lastDayOf, parseRange, TimeRange, weekdayName } from "./time-range";
import { useNoteDetails } from "./use-note-details";
import { useWatchlist } from "./use-watchlist";
import { addWatch, removeWatch, WatchItem } from "./watchlist";
import {
  buildNoteMarkdown,
  formatDate,
  formatDateTime,
  shortTime,
  truncate,
} from "./utils";

/**
 * 输入决定显示什么：
 *  - 留空            → 最近 7 天时间线（笔记 + 待办）
 *  - 时间词          → 对应时间线：昨天 / 上周 / 本月 / 周三 / 10月3日 / 最近14天 / 10月1日到10月7日
 *  - 「日记」开头    → Daily Note 列表，后面可接日期或关键词过滤：日记 上周
 *  - 「档案 名字」   → 人物 / 主题档案（也可写成 @名字）
 *  - 「回顾」「随机」 → 往日回顾：N 周 / 月 / 年前的今天 + 随机一条旧笔记
 *  - 其他文字        → 语义搜索
 */
type Intent =
  | { kind: "timeline"; range: TimeRange }
  | { kind: "search"; query: string }
  | { kind: "dossier"; query: string }
  | { kind: "memory" }
  | { kind: "daily"; rest: string };

type View =
  | { kind: "timeline"; data: TimelineData }
  | { kind: "search"; notes: NoteInfo[] }
  | { kind: "dossier"; data: DossierData }
  | { kind: "memory"; data: MemoryData; pick: NoteInfo | null }
  | { kind: "daily"; notes: NoteInfo[]; folderFound: boolean; rest: string };

function resolveIntent(
  query: string,
  dailyOnly: boolean,
  forceSearchFor: string | null,
  dossierOf?: string,
  dossierOnly?: boolean,
  memoryOnly?: boolean,
): Intent {
  const q = query.trim();
  if (memoryOnly && !q) return { kind: "memory" };
  if (dossierOf) return { kind: "dossier", query: dossierOf };
  if (dossierOnly) return { kind: "dossier", query: q };
  if (dailyOnly) return { kind: "daily", rest: q };

  const dossier =
    q.match(/^(?:档案|简报|人物|主题|profile|dossier)(?:\s+(.*))?$/i) ??
    q.match(/^@\s*(.+)$/);
  if (dossier) return { kind: "dossier", query: (dossier[1] ?? "").trim() };

  if (
    /^(?:回顾|往日|往日回顾|那年今日|往年今日|今日回顾|随机|随机一条|random|memory)$/i.test(
      q,
    )
  )
    return { kind: "memory" };

  const daily = q.match(/^(?:日记|daily)(?:\s+(.*))?$/i);
  if (daily) return { kind: "daily", rest: (daily[1] ?? "").trim() };

  if (!q) return { kind: "timeline", range: parseRange("") as TimeRange };
  if (forceSearchFor === q) return { kind: "search", query: q };

  const range = parseRange(q);
  return range ? { kind: "timeline", range } : { kind: "search", query: q };
}

function filterDaily(
  all: NoteInfo[],
  rest: string,
  bodyOf: (id: string) => string | undefined,
): NoteInfo[] {
  if (!rest) return all;

  const range = parseRange(rest);
  if (range) {
    const from = formatDate(range.start);
    const to = formatDate(lastDayOf(range));
    return all.filter((n) => {
      const d = extractDate(n.title);
      return d >= from && d <= to;
    });
  }

  const kw = rest.toLowerCase();
  return all.filter(
    (n) =>
      n.title.toLowerCase().includes(kw) ||
      (bodyOf(getNoteId(n)) ?? "").toLowerCase().includes(kw),
  );
}

function firstNoteId(view: View): string | undefined {
  if (view.kind === "timeline") {
    const note = view.data.days.find((d) => d.notes.length > 0)?.notes[0];
    return note ? getNoteId(note) : undefined;
  }
  if (view.kind === "memory") {
    const first = view.pick ?? view.data.sameDay[0]?.notes[0];
    return first ? getNoteId(first) : undefined;
  }
  if (view.kind === "dossier") {
    const first = view.data.notes.find((n) => n.direct) ?? view.data.notes[0];
    return first ? getNoteId(first.note) : undefined;
  }
  return view.notes[0] ? getNoteId(view.notes[0]) : undefined;
}

const NON_NOTE_ID = /^(t-|qe-|overview|watch-)/;

export default function Command(
  props: LaunchProps<{ arguments: { query?: string } }>,
) {
  const query = props.arguments?.query?.trim() ?? "";
  // Todos / 菜单栏通过暗号参数打开待办列表（待办列表不再有单独的命令）
  if (query === TODOS_LIST_QUERY) return <TodosList />;
  return <NotesBrowser initialQuery={query} />;
}

export function NotesBrowser({
  dailyOnly = false,
  dossierOf,
  dossierOnly = false,
  memoryOnly = false,
  initialQuery = "",
}: {
  dailyOnly?: boolean;
  dossierOf?: string;
  dossierOnly?: boolean;
  memoryOnly?: boolean;
  initialQuery?: string;
}) {
  const [query, setQuery] = useState(initialQuery);
  const [view, setView] = useState<View | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [tick, setTick] = useState(0);
  const [forceSearchFor, setForceSearchFor] = useState<string | null>(null);
  const dailyCache = useRef<{ notes: NoteInfo[]; folderFound: boolean } | null>(
    null,
  );
  const memoryCache = useRef<MemoryData | null>(null);
  const { details, loadingId, load, prefetch, reset } = useNoteDetails();
  const { items: watchItems } = useWatchlist(false, 0);

  const intent = useMemo(
    () =>
      resolveIntent(
        query,
        dailyOnly,
        forceSearchFor,
        dossierOf,
        dossierOnly,
        memoryOnly,
      ),
    [query, dailyOnly, forceSearchFor, dossierOf, dossierOnly, memoryOnly],
  );

  useEffect(() => {
    let cancelled = false;
    const cachedLocal =
      (intent.kind === "daily" && dailyCache.current !== null) ||
      (intent.kind === "memory" && memoryCache.current !== null);
    const delay =
      cachedLocal || intent.kind === "memory" || !query.trim() ? 0 : 350;

    const timer = setTimeout(async () => {
      setIsLoading(true);
      try {
        let next: View;
        if (intent.kind === "timeline") {
          next = { kind: "timeline", data: await loadTimeline(intent.range) };
        } else if (intent.kind === "search") {
          next = { kind: "search", notes: await searchNotes(intent.query) };
        } else if (intent.kind === "dossier") {
          next = { kind: "dossier", data: await loadDossier(intent.query) };
        } else if (intent.kind === "memory") {
          if (!memoryCache.current) memoryCache.current = await loadMemory();
          next = {
            kind: "memory",
            data: memoryCache.current,
            pick: pickRandom(
              memoryCache.current.pool,
              sameDayIds(memoryCache.current),
            ),
          };
        } else {
          if (!dailyCache.current) {
            const { notes, folder } = await listDailyNotes();
            dailyCache.current = { notes, folderFound: !!folder };
          }
          next = { kind: "daily", ...dailyCache.current, rest: intent.rest };
        }
        if (cancelled) return;
        setView(next);
        const first = firstNoteId(next);
        if (first) load(first);
        // 概览的字数 / 标签分析需要正文：后台预取（最多 40 条，最新的优先）
        if (next.kind === "timeline") {
          prefetch(
            next.data.days
              .flatMap((d) => d.notes)
              .slice(0, 40)
              .map(getNoteId),
          );
        }
      } catch (error) {
        if (!cancelled) {
          await showToast({
            style: Toast.Style.Failure,
            title: "加载失败",
            message: error instanceof Error ? error.message : String(error),
          });
        }
      } finally {
        if (!cancelled) setIsLoading(false);
      }
    }, delay);

    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [intent, query, tick, load, prefetch]);

  const refresh = () => {
    dailyCache.current = null;
    memoryCache.current = null;
    reset();
    setTick((t) => t + 1);
  };

  const bodyOf = (id: string) => {
    const d = details[id];
    return d ? d.content || d.body || "" : undefined;
  };

  const dailyShown = useMemo(
    () =>
      view?.kind === "daily" ? filterDaily(view.notes, view.rest, bodyOf) : [],
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [view, details],
  );

  async function toggleTodo(todo: TodoItem) {
    try {
      await updateTodos([
        { todo_id: todo.id, is_completed: !todo.is_completed },
      ]);
      setTick((t) => t + 1);
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "操作失败",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  const today = formatDate(new Date());

  // ── 通用动作 ──
  const refreshAction = (
    <Action
      title="刷新"
      icon={Icon.ArrowClockwise}
      shortcut={{ modifiers: ["cmd"], key: "r" }}
      onAction={refresh}
    />
  );
  const keywordSearchAction =
    intent.kind === "timeline" && query.trim() ? (
      <Action
        title={`按关键词搜索「${truncate(query.trim(), 12)}」`}
        icon={Icon.MagnifyingGlass}
        shortcut={{ modifiers: ["cmd"], key: "f" }}
        onAction={() => setForceSearchFor(query.trim())}
      />
    ) : null;

  // ── 笔记条目（三种视图共用） ──
  const renderNote = (
    note: NoteInfo,
    accessories: List.Item.Accessory[],
    report?: string,
    withReroll = false,
  ) => {
    const id = getNoteId(note);
    const detail = details[id];
    const body = bodyOf(id);
    const summary = detail?.summary || note.summary;
    const created = note.created_at || detail?.created_at;
    const tags = detail?.tags ?? note.tags ?? [];
    const title = note.title || "无标题";
    const isThisLoading = loadingId === id;

    return (
      <List.Item
        key={id}
        id={id}
        title={title}
        icon={Icon.Document}
        accessories={accessories}
        detail={
          <List.Item.Detail
            isLoading={isThisLoading}
            markdown={buildNoteMarkdown({
              title,
              summary,
              body,
              loading: isThisLoading,
            })}
            metadata={
              <List.Item.Detail.Metadata>
                {created && (
                  <List.Item.Detail.Metadata.Label
                    title="创建时间"
                    text={formatDateTime(created)}
                  />
                )}
                {tags.length > 0 && (
                  <List.Item.Detail.Metadata.TagList title="标签">
                    {tags.slice(0, 8).map((t) => (
                      <List.Item.Detail.Metadata.TagList.Item
                        key={t}
                        text={t}
                      />
                    ))}
                  </List.Item.Detail.Metadata.TagList>
                )}
              </List.Item.Detail.Metadata>
            }
          />
        }
        actions={
          <ActionPanel>
            <Action.Push
              title="查看全文"
              icon={Icon.Eye}
              target={
                <NoteDetailView noteId={id} title={title} summary={summary} />
              }
            />
            {withReroll && (
              <Action
                title="换一条"
                icon={Icon.Shuffle}
                shortcut={{ modifiers: ["cmd"], key: "d" }}
                onAction={rerollRandom}
              />
            )}
            {report && (
              <Action.CopyToClipboard
                title="复制为 Markdown 回顾"
                icon={Icon.Clipboard}
                content={report}
                shortcut={{ modifiers: ["cmd"], key: "return" }}
              />
            )}
            {body && (
              <Action.CopyToClipboard
                title="复制正文"
                content={body}
                shortcut={{ modifiers: ["cmd"], key: "c" }}
              />
            )}
            {summary && (
              <Action.CopyToClipboard
                title="复制摘要"
                content={summary}
                shortcut={{ modifiers: ["cmd", "opt"], key: "c" }}
              />
            )}
            <Action.CopyToClipboard
              title="复制标题"
              content={title}
              shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
            />
            {tags
              .slice(0, 3)
              .filter(
                (t) =>
                  !watchItems.some(
                    (w) => w.keyword.toLowerCase() === t.toLowerCase(),
                  ),
              )
              .map((t) => (
                <Action
                  key={`watch-${t}`}
                  title={`钉为项目「${t}」`}
                  icon={Icon.Pin}
                  onAction={async () => {
                    await addWatch(t);
                    await showToast({
                      style: Toast.Style.Success,
                      title: `已钉为项目「${t}」`,
                    });
                  }}
                />
              ))}
            {tags.slice(0, 3).map((t) => (
              <Action.Push
                key={`dossier-${t}`}
                title={`查看「${t}」档案`}
                icon={Icon.Person}
                target={<NotesBrowser dossierOf={t} />}
              />
            ))}
            {keywordSearchAction}
            {refreshAction}
          </ActionPanel>
        }
      />
    );
  };

  // ── 概览 / 档案：Markdown 叙述 + 元信息行 ──
  const docDetail = (doc: DetailDoc) => (
    <List.Item.Detail
      markdown={doc.markdown}
      metadata={
        doc.rows.length > 0 || doc.tags.length > 0 ? (
          <List.Item.Detail.Metadata>
            {doc.rows.map((r, i) =>
              r ? (
                <List.Item.Detail.Metadata.Label
                  key={`${r.title}-${i}`}
                  title={r.title}
                  text={r.text}
                />
              ) : (
                <List.Item.Detail.Metadata.Separator key={`sep-${i}`} />
              ),
            )}
            {doc.tags.length > 0 && (
              <List.Item.Detail.Metadata.TagList title={doc.tagsTitle}>
                {doc.tags.map((t) => (
                  <List.Item.Detail.Metadata.TagList.Item key={t} text={t} />
                ))}
              </List.Item.Detail.Metadata.TagList>
            )}
          </List.Item.Detail.Metadata>
        ) : undefined
      }
    />
  );

  // ── 概览里的「今天 / 昨天」 ──
  const renderDayOverview = (
    data: TimelineData,
    daysAgo: number,
    label: string,
  ) => {
    const d = new Date();
    d.setDate(d.getDate() - daysAgo);
    const date = formatDate(d);
    const sliced = sliceDay(data, date, `${label} · ${date}`);
    const hasData = sliced.days.length > 0;
    const prev = new Date(d);
    prev.setDate(prev.getDate() - 1);
    const doc = buildDayOverview(
      label,
      date,
      findDay(data, date),
      findDay(data, formatDate(prev)),
      daysAgo === 0 ? "昨天" : "前天",
      details,
      today,
    );
    return (
      <List.Item
        key={`overview-${daysAgo}`}
        id={`overview-day-${daysAgo}`}
        title={label}
        subtitle={
          hasData
            ? `${date} · ${sliced.noteCount} 条笔记${sliced.todoTotal ? ` · 待办 ${sliced.todoDone}/${sliced.todoTotal} 完成` : ""}`
            : `${date} · 暂无记录`
        }
        icon={{
          source: daysAgo === 0 ? Icon.Sun : Icon.Clock,
          tintColor: daysAgo === 0 ? Color.Orange : Color.Blue,
        }}
        detail={docDetail(doc)}
        actions={
          <ActionPanel>
            {hasData && (
              <Action.CopyToClipboard
                title={`复制${label}的 Markdown 回顾`}
                icon={Icon.Clipboard}
                content={doc.copy}
                shortcut={{ modifiers: ["cmd"], key: "return" }}
              />
            )}
            {refreshAction}
          </ActionPanel>
        }
      />
    );
  };

  // ── 时间线 ──
  const renderTimeline = (data: TimelineData) => {
    const overviewDoc = buildRangeOverview(data, details, today);
    const report = overviewDoc.copy;
    const copyReport = (
      <Action.CopyToClipboard
        title="复制为 Markdown 回顾"
        icon={Icon.Clipboard}
        content={report}
        shortcut={{ modifiers: ["cmd"], key: "return" }}
      />
    );

    return (
      <>
        {!dailyOnly && !query.trim() && (
          <List.Section title="快捷入口">
            <List.Item
              id="qe-daily"
              title="Daily Note"
              subtitle="浏览每日日记"
              icon={{ source: Icon.Calendar, tintColor: Color.Blue }}
              accessories={[{ text: "输入「日记」也可进入" }]}
              detail={
                <List.Item.Detail
                  markdown={
                    "# Daily Note\n\n浏览 Daily Note 文件夹里的每日日记。\n\n- 进入后可输入 `上周`、`10月3日` 按日期过滤\n- 或输入关键词按标题 / 内容过滤\n- 在搜索栏直接输入 `日记` 或 `日记 上周` 也能到这里"
                  }
                />
              }
              actions={
                <ActionPanel>
                  <Action.Push
                    title="打开 Daily Note"
                    icon={Icon.Calendar}
                    target={<NotesBrowser dailyOnly />}
                  />
                </ActionPanel>
              }
            />
            <List.Item
              id="qe-memory"
              title="往日回顾"
              subtitle="那年今日 / 随机一条"
              icon={{ source: Icon.Shuffle, tintColor: Color.Green }}
              accessories={[{ text: "输入「回顾」也可进入" }]}
              detail={
                <List.Item.Detail
                  markdown={
                    "# 往日回顾\n\n不整理的笔记，最需要的是被重新看见。\n\n- **N 周 / 月 / 年前的今天**：按日历推算，列出当天写过的笔记\n- **随机一条**：从全部笔记里抽一条旧的，不满意可以立刻换一条\n\n在搜索栏输入 `回顾` 或 `随机` 也能到这里。"
                  }
                />
              }
              actions={
                <ActionPanel>
                  <Action.Push
                    title="打开往日回顾"
                    icon={Icon.Shuffle}
                    target={<NotesBrowser memoryOnly />}
                  />
                </ActionPanel>
              }
            />
            <List.Item
              id="qe-dossier"
              title="人物 / 主题档案"
              subtitle="见面前简报"
              icon={{ source: Icon.Person, tintColor: Color.Purple }}
              accessories={[{ text: "输入「档案 名字」" }]}
              detail={
                <List.Item.Detail
                  markdown={
                    "# 人物 / 主题档案\n\n围绕一个名字或主题，聚合你过往的全部记忆：\n\n- 首次 / 最近提及，累计提及次数\n- 近 12 个月提及频率（迷你图）\n- 常伴随的标签\n- 最近的提及片段\n- 相关待办、该说话人的录音笔记\n\n**用法**：在搜索栏输入 `档案 张三`、`档案 定价`，或 `@张三`。开会 / 见面前一键「我都知道什么」。"
                  }
                />
              }
              actions={
                <ActionPanel>
                  <Action.Push
                    title="生成档案"
                    icon={Icon.Person}
                    target={<NotesBrowser dossierOnly />}
                  />
                </ActionPanel>
              }
            />
          </List.Section>
        )}

        {(data.days.length > 0 || !query.trim()) && (
          <List.Section title="概览">
            {!dailyOnly && !query.trim() && (
              <>
                {renderDayOverview(data, 0, "今天")}
                {renderDayOverview(data, 1, "昨天")}
              </>
            )}
            {data.days.length > 0 && (
              <List.Item
                id="overview"
                title={data.range.label}
                subtitle={`${data.noteCount} 条笔记 · 待办 ${data.todoDone}/${data.todoTotal} 完成`}
                icon={{ source: Icon.Calendar, tintColor: Color.Blue }}
                accessories={[
                  ...(data.range.clamped
                    ? [
                        {
                          tag: { value: "已截断至 62 天", color: Color.Orange },
                        },
                      ]
                    : []),
                  ...(data.truncated
                    ? [
                        {
                          tag: {
                            value: "部分时段笔记过多",
                            color: Color.Orange,
                          },
                        },
                      ]
                    : []),
                ]}
                detail={docDetail(overviewDoc)}
                actions={
                  <ActionPanel>
                    {copyReport}
                    {keywordSearchAction}
                    {refreshAction}
                  </ActionPanel>
                }
              />
            )}
          </List.Section>
        )}

        {data.days.map((day) => (
          <List.Section
            key={day.date}
            title={day.title}
            subtitle={`${day.todos.length ? `${day.todos.length} 待办 · ` : ""}${day.notes.length} 笔记`}
          >
            {day.todos.map((todo) => (
              <List.Item
                key={`t-${todo.id}`}
                id={`t-${todo.id}`}
                title={todo.content}
                icon={
                  todo.is_completed
                    ? { source: Icon.CheckCircle, tintColor: Color.Green }
                    : { source: Icon.Circle, tintColor: Color.SecondaryText }
                }
                accessories={[
                  ...(todo.time
                    ? [{ tag: { value: todo.time, color: Color.Blue } }]
                    : []),
                  { text: "待办" },
                ]}
                detail={
                  <List.Item.Detail
                    markdown={`# ${todo.is_completed ? "✅" : "⬜️"} ${todo.content}`}
                    metadata={
                      <List.Item.Detail.Metadata>
                        <List.Item.Detail.Metadata.Label
                          title="状态"
                          text={todo.is_completed ? "已完成" : "未完成"}
                        />
                        {todo.date && (
                          <List.Item.Detail.Metadata.Label
                            title="日期"
                            text={todo.date}
                          />
                        )}
                        {todo.time && (
                          <List.Item.Detail.Metadata.Label
                            title="时间"
                            text={todo.time}
                          />
                        )}
                      </List.Item.Detail.Metadata>
                    }
                  />
                }
                actions={
                  <ActionPanel>
                    <Action
                      title={todo.is_completed ? "恢复为未完成" : "标记完成"}
                      icon={todo.is_completed ? Icon.Circle : Icon.CheckCircle}
                      onAction={() => toggleTodo(todo)}
                    />
                    {copyReport}
                    {refreshAction}
                  </ActionPanel>
                }
              />
            ))}
            {day.notes.map((n) =>
              renderNote(n, [{ text: localHHmm(n.created_at) }], report),
            )}
          </List.Section>
        ))}
      </>
    );
  };

  // ── 人物 / 主题档案 ──
  const pinAction = (keyword: string) => {
    const watched = watchItems.some(
      (w: WatchItem) => w.keyword.toLowerCase() === keyword.toLowerCase(),
    );
    return watched ? (
      <Action
        title="取消项目关注"
        icon={Icon.XMarkCircle}
        shortcut={{ modifiers: ["cmd"], key: "p" }}
        onAction={async () => {
          await removeWatch(keyword);
          await showToast({
            style: Toast.Style.Success,
            title: `已取消项目「${keyword}」`,
          });
        }}
      />
    ) : (
      <Action
        title="钉为项目（在 Todos 里管理）"
        icon={Icon.Pin}
        shortcut={{ modifiers: ["cmd"], key: "p" }}
        onAction={async () => {
          await addWatch(keyword);
          await showToast({
            style: Toast.Style.Success,
            title: `已钉为项目「${keyword}」`,
            message: "打开 Todos，「项目」分区里就能看到",
          });
        }}
      />
    );
  };

  const renderDossier = (data: DossierData) => {
    if (!data.query) return null;
    const copyBrief = (
      <Action.CopyToClipboard
        title="复制简报（Markdown）"
        icon={Icon.Clipboard}
        content={data.brief}
        shortcut={{ modifiers: ["cmd"], key: "return" }}
      />
    );
    const direct = data.notes.filter((n) => n.direct);
    const related = data.notes.filter((n) => !n.direct);
    const noteAccessories = (n: DossierNote): List.Item.Accessory[] => [
      ...(n.viaSpeaker
        ? [{ tag: { value: "录音", color: Color.Purple } }]
        : []),
      ...(n.mentions > 0
        ? [{ tag: { value: `提及 ×${n.mentions}`, color: Color.Green } }]
        : []),
      { text: n.day ? n.day.slice(2) : "" },
    ];

    return (
      <>
        <List.Section title="简报">
          <List.Item
            id="overview-dossier"
            title={`「${data.query}」档案`}
            subtitle={`直接提及 ${data.directCount} 条 · 待办 ${data.todos.length}`}
            icon={{ source: Icon.Person, tintColor: Color.Purple }}
            detail={docDetail(data.doc)}
            actions={
              <ActionPanel>
                {copyBrief}
                {pinAction(data.query)}
                {refreshAction}
              </ActionPanel>
            }
          />
        </List.Section>

        {data.todos.length > 0 && (
          <List.Section title="相关待办" subtitle={`${data.todos.length}`}>
            {data.todos.map((todo) => (
              <List.Item
                key={`t-${todo.id}`}
                id={`t-${todo.id}`}
                title={todo.content}
                icon={
                  todo.is_completed
                    ? { source: Icon.CheckCircle, tintColor: Color.Green }
                    : { source: Icon.Circle, tintColor: Color.SecondaryText }
                }
                accessories={[
                  ...(todo.time
                    ? [{ tag: { value: todo.time, color: Color.Blue } }]
                    : []),
                  { text: todo.date ?? "无日期" },
                ]}
                detail={
                  <List.Item.Detail
                    markdown={`# ${todo.is_completed ? "✅" : "⬜️"} ${todo.content}`}
                  />
                }
                actions={
                  <ActionPanel>
                    <Action
                      title={todo.is_completed ? "恢复为未完成" : "标记完成"}
                      icon={todo.is_completed ? Icon.Circle : Icon.CheckCircle}
                      onAction={() => toggleTodo(todo)}
                    />
                    {copyBrief}
                    {refreshAction}
                  </ActionPanel>
                }
              />
            ))}
          </List.Section>
        )}

        {direct.length > 0 && (
          <List.Section title="直接提及" subtitle={`${direct.length}`}>
            {direct.map((n) =>
              renderNote(n.note, noteAccessories(n), data.brief),
            )}
          </List.Section>
        )}
        {related.length > 0 && (
          <List.Section title="可能相关" subtitle={`${related.length}`}>
            {related.map((n) =>
              renderNote(n.note, noteAccessories(n), data.brief),
            )}
          </List.Section>
        )}
      </>
    );
  };

  // ── 往日回顾：随机一条 + N 周 / 月 / 年前的今天 ──
  const rerollRandom = () => {
    if (view?.kind !== "memory") return;
    const pick = pickRandom(view.data.pool, [
      ...sameDayIds(view.data),
      ...(view.pick ? [getNoteId(view.pick)] : []),
    ]);
    setView({ ...view, pick });
    if (pick) load(getNoteId(pick));
  };

  const renderMemory = (data: MemoryData, pick: NoteInfo | null) => {
    const withReroll = (note: NoteInfo, accessories: List.Item.Accessory[]) =>
      renderNote(note, accessories, undefined, true);

    return (
      <>
        <List.Section
          title="随机一条"
          subtitle={
            data.pool.length ? `共 ${data.pool.length} 条可抽取` : undefined
          }
        >
          {pick ? (
            withReroll(pick, [
              { tag: { value: "随机", color: Color.Green } },
              { text: pick.created_at ? shortTime(pick.created_at) : "" },
            ])
          ) : (
            <List.Item
              id="qe-memory-empty"
              title="还没有可以抽取的笔记"
              icon={Icon.Shuffle}
            />
          )}
        </List.Section>

        {data.sameDay.length === 0 ? (
          <List.Section title="往日的今天">
            <List.Item
              id="qe-memory-none"
              title="往日的今天没有记录"
              subtitle="1 周前 · 2 周前 · 1 / 2 / 3 / 6 个月前 · 每满 1 年的今天"
              icon={{ source: Icon.Clock, tintColor: Color.SecondaryText }}
            />
          </List.Section>
        ) : (
          data.sameDay.map((g) => (
            <List.Section
              key={g.date}
              title={g.label}
              subtitle={`${g.date} · ${g.notes.length} 条`}
            >
              {g.notes.map((n) =>
                withReroll(n, [{ text: localHHmm(n.created_at) }]),
              )}
            </List.Section>
          ))
        )}
      </>
    );
  };

  // ── Daily Note 列表（按月分组） ──
  const renderDaily = (notes: NoteInfo[]) => {
    const groups = new Map<string, NoteInfo[]>();
    for (const n of notes) {
      const date = extractDate(n.title);
      const key = date
        ? `${date.slice(0, 4)} 年 ${Number(date.slice(5, 7))} 月`
        : "其他";
      groups.set(key, [...(groups.get(key) ?? []), n]);
    }

    return [...groups.entries()].map(([title, list]) => (
      <List.Section key={title} title={title} subtitle={`${list.length}`}>
        {list.map((n) => {
          const date = extractDate(n.title);
          const isToday = date === today;
          const weekday = date ? weekdayName(new Date(`${date}T00:00:00`)) : "";
          return renderNote(n, [
            ...(isToday ? [{ tag: { value: "今天", color: Color.Blue } }] : []),
            ...(weekday ? [{ text: weekday }] : []),
          ]);
        })}
      </List.Section>
    ));
  };

  // ── 空状态 ──
  const hasItems =
    view !== null &&
    (view.kind === "timeline"
      ? view.data.days.length > 0 || (!dailyOnly && !query.trim())
      : view.kind === "search"
        ? view.notes.length > 0
        : view.kind === "memory"
          ? true
          : view.kind === "dossier"
            ? !!view.data.query &&
              (view.data.notes.length > 0 || view.data.todos.length > 0)
            : dailyShown.length > 0);

  const emptyTitle =
    view?.kind === "dossier"
      ? view.data.query
        ? `没有找到与「${view.data.query}」相关的内容`
        : "输入「档案 名字」生成人物 / 主题档案"
      : view?.kind === "timeline"
        ? `${view.data.range.label} 没有记录`
        : view?.kind === "daily"
          ? view.folderFound
            ? view.rest
              ? "没有匹配的 Daily Note"
              : "文件夹里还没有 Daily Note"
            : "没有找到 Daily Note 文件夹"
          : "没有找到匹配的笔记";
  const emptyDescription =
    view?.kind === "dossier"
      ? "例如：档案 张三、档案 定价、@项目代号；也可以换个叫法（全名 / 昵称）再试"
      : view?.kind === "daily" && !view.folderFound
        ? "请在偏好设置里检查 Daily Note Folder 名称，或在万能输入里写一条日记来自动创建"
        : view?.kind === "search"
          ? "换个关键词试试；输入「昨天」「上周」这类时间词可以看时间线"
          : "换个时间 / 关键词试试，或者现在就用 Smart Capture 记一条";

  return (
    <List
      isLoading={isLoading}
      isShowingDetail={hasItems}
      filtering={false}
      searchText={query}
      throttle
      onSearchTextChange={setQuery}
      onSelectionChange={(id) => {
        if (id && !NON_NOTE_ID.test(id)) load(id);
      }}
      searchBarPlaceholder={
        dailyOnly
          ? "Daily Note：输入日期（上周 / 10月3日）或关键词过滤"
          : dossierOnly
            ? "输入人物 / 主题名字，如 张三、定价、某项目"
            : dossierOf
              ? "档案"
              : "搜索笔记 · 昨天 / 上周 看时间线 · 「日记」看 Daily Note · 「档案 名字」看人物 / 主题档案"
      }
    >
      {view?.kind === "timeline" && renderTimeline(view.data)}

      {view?.kind === "search" && (
        <List.Section title="搜索结果" subtitle={`${view.notes.length}`}>
          {view.notes.map((n) => {
            const created = n.created_at;
            return renderNote(n, created ? [{ text: shortTime(created) }] : []);
          })}
        </List.Section>
      )}

      {view?.kind === "dossier" && renderDossier(view.data)}

      {view?.kind === "memory" && renderMemory(view.data, view.pick)}

      {view?.kind === "daily" && renderDaily(dailyShown)}

      {!isLoading && !hasItems && view && (
        <List.EmptyView
          icon={Icon.MagnifyingGlass}
          title={emptyTitle}
          description={emptyDescription}
        />
      )}
    </List>
  );
}
