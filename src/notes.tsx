import { Action, ActionPanel, Color, Icon, List, showToast, Toast } from "@raycast/api";
import { useEffect, useMemo, useRef, useState } from "react";
import { getNoteId, NoteInfo, searchNotes, TodoItem, updateTodos } from "./api";
import { extractDate, listDailyNotes } from "./daily";
import { NoteDetailView } from "./note-detail-view";
import { buildReport, loadTimeline, localHHmm, TimelineData } from "./timeline-data";
import { lastDayOf, parseRange, TimeRange, weekdayName } from "./time-range";
import { useNoteDetails } from "./use-note-details";
import { buildNoteMarkdown, formatDate, formatDateTime, shortTime, truncate } from "./utils";

/**
 * 输入决定显示什么：
 *  - 留空            → 最近 7 天时间线（笔记 + 待办）
 *  - 时间词          → 对应时间线：昨天 / 上周 / 本月 / 周三 / 10月3日 / 最近14天 / 10月1日到10月7日
 *  - 「日记」开头    → Daily Note 列表，后面可接日期或关键词过滤：日记 上周
 *  - 其他文字        → 语义搜索
 */
type Intent =
  | { kind: "timeline"; range: TimeRange }
  | { kind: "search"; query: string }
  | { kind: "daily"; rest: string };

type View =
  | { kind: "timeline"; data: TimelineData }
  | { kind: "search"; notes: NoteInfo[] }
  | { kind: "daily"; notes: NoteInfo[]; folderFound: boolean; rest: string };

function resolveIntent(query: string, dailyOnly: boolean, forceSearchFor: string | null): Intent {
  const q = query.trim();
  if (dailyOnly) return { kind: "daily", rest: q };

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
    (n) => n.title.toLowerCase().includes(kw) || (bodyOf(getNoteId(n)) ?? "").toLowerCase().includes(kw),
  );
}

function firstNoteId(view: View): string | undefined {
  if (view.kind === "timeline") {
    const note = view.data.days.find((d) => d.notes.length > 0)?.notes[0];
    return note ? getNoteId(note) : undefined;
  }
  return view.notes[0] ? getNoteId(view.notes[0]) : undefined;
}

const NON_NOTE_ID = /^(t-|qe-|overview)/;

export default function Command() {
  return <NotesBrowser />;
}

function NotesBrowser({ dailyOnly = false }: { dailyOnly?: boolean }) {
  const [query, setQuery] = useState("");
  const [view, setView] = useState<View | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [tick, setTick] = useState(0);
  const [forceSearchFor, setForceSearchFor] = useState<string | null>(null);
  const dailyCache = useRef<{ notes: NoteInfo[]; folderFound: boolean } | null>(null);
  const { details, loadingId, load, reset } = useNoteDetails();

  const intent = useMemo(() => resolveIntent(query, dailyOnly, forceSearchFor), [query, dailyOnly, forceSearchFor]);

  useEffect(() => {
    let cancelled = false;
    const cachedDaily = intent.kind === "daily" && dailyCache.current !== null;
    const delay = cachedDaily || !query.trim() ? 0 : 350;

    const timer = setTimeout(async () => {
      setIsLoading(true);
      try {
        let next: View;
        if (intent.kind === "timeline") {
          next = { kind: "timeline", data: await loadTimeline(intent.range) };
        } else if (intent.kind === "search") {
          next = { kind: "search", notes: await searchNotes(intent.query) };
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
  }, [intent, query, tick, load]);

  const refresh = () => {
    dailyCache.current = null;
    reset();
    setTick((t) => t + 1);
  };

  const bodyOf = (id: string) => {
    const d = details[id];
    return d ? d.content || d.body || "" : undefined;
  };

  const dailyShown = useMemo(
    () => (view?.kind === "daily" ? filterDaily(view.notes, view.rest, bodyOf) : []),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [view, details],
  );

  async function toggleTodo(todo: TodoItem) {
    try {
      await updateTodos([{ todo_id: todo.id, is_completed: !todo.is_completed }]);
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
    <Action title="刷新" icon={Icon.ArrowClockwise} shortcut={{ modifiers: ["cmd"], key: "r" }} onAction={refresh} />
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
  const renderNote = (note: NoteInfo, accessories: List.Item.Accessory[], report?: string) => {
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
            markdown={buildNoteMarkdown({ title, summary, body, loading: isThisLoading })}
            metadata={
              <List.Item.Detail.Metadata>
                {created && <List.Item.Detail.Metadata.Label title="创建时间" text={formatDateTime(created)} />}
                {tags.length > 0 && (
                  <List.Item.Detail.Metadata.TagList title="标签">
                    {tags.slice(0, 8).map((t) => (
                      <List.Item.Detail.Metadata.TagList.Item key={t} text={t} />
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
              target={<NoteDetailView noteId={id} title={title} summary={summary} />}
            />
            {report && (
              <Action.CopyToClipboard
                title="复制为 Markdown 回顾"
                icon={Icon.Clipboard}
                content={report}
                shortcut={{ modifiers: ["cmd"], key: "return" }}
              />
            )}
            {body && (
              <Action.CopyToClipboard title="复制正文" content={body} shortcut={{ modifiers: ["cmd"], key: "c" }} />
            )}
            {summary && (
              <Action.CopyToClipboard
                title="复制摘要"
                content={summary}
                shortcut={{ modifiers: ["cmd", "opt"], key: "c" }}
              />
            )}
            <Action.CopyToClipboard title="复制标题" content={title} shortcut={{ modifiers: ["cmd", "shift"], key: "c" }} />
            {keywordSearchAction}
            {refreshAction}
          </ActionPanel>
        }
      />
    );
  };

  // ── 时间线 ──
  const renderTimeline = (data: TimelineData) => {
    const report = buildReport(data);
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
                  <Action.Push title="打开 Daily Note" icon={Icon.Calendar} target={<NotesBrowser dailyOnly />} />
                </ActionPanel>
              }
            />
          </List.Section>
        )}

        {data.days.length > 0 && (
          <List.Section title="概览">
            <List.Item
              id="overview"
              title={data.range.label}
              subtitle={`${data.noteCount} 条笔记 · 待办 ${data.todoDone}/${data.todoTotal} 完成`}
              icon={{ source: Icon.Calendar, tintColor: Color.Blue }}
              accessories={[
                ...(data.range.clamped ? [{ tag: { value: "已截断至 62 天", color: Color.Orange } }] : []),
                ...(data.truncated ? [{ tag: { value: "部分时段笔记过多", color: Color.Orange } }] : []),
              ]}
              detail={<List.Item.Detail markdown={report} />}
              actions={
                <ActionPanel>
                  {copyReport}
                  {keywordSearchAction}
                  {refreshAction}
                </ActionPanel>
              }
            />
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
                  ...(todo.time ? [{ tag: { value: todo.time, color: Color.Blue } }] : []),
                  { text: "待办" },
                ]}
                detail={
                  <List.Item.Detail
                    markdown={`# ${todo.is_completed ? "✅" : "⬜️"} ${todo.content}`}
                    metadata={
                      <List.Item.Detail.Metadata>
                        <List.Item.Detail.Metadata.Label title="状态" text={todo.is_completed ? "已完成" : "未完成"} />
                        {todo.date && <List.Item.Detail.Metadata.Label title="日期" text={todo.date} />}
                        {todo.time && <List.Item.Detail.Metadata.Label title="时间" text={todo.time} />}
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
            {day.notes.map((n) => renderNote(n, [{ text: localHHmm(n.created_at) }], report))}
          </List.Section>
        ))}
      </>
    );
  };

  // ── Daily Note 列表（按月分组） ──
  const renderDaily = (notes: NoteInfo[]) => {
    const groups = new Map<string, NoteInfo[]>();
    for (const n of notes) {
      const date = extractDate(n.title);
      const key = date ? `${date.slice(0, 4)} 年 ${Number(date.slice(5, 7))} 月` : "其他";
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
        : dailyShown.length > 0);

  const emptyTitle =
    view?.kind === "timeline"
      ? `${view.data.range.label} 没有记录`
      : view?.kind === "daily"
        ? view.folderFound
          ? view.rest
            ? "没有匹配的 Daily Note"
            : "文件夹里还没有 Daily Note"
          : "没有找到 Daily Note 文件夹"
        : "没有找到匹配的笔记";
  const emptyDescription =
    view?.kind === "daily" && !view.folderFound
      ? "请在偏好设置里检查 Daily Note Folder 名称，或在万能输入里写一条日记来自动创建"
      : view?.kind === "search"
        ? "换个关键词试试；输入「昨天」「上周」这类时间词可以看时间线"
        : "换个时间 / 关键词试试，或者现在就用 Smart Capture 记一条";

  return (
    <List
      isLoading={isLoading}
      isShowingDetail={hasItems}
      filtering={false}
      throttle
      onSearchTextChange={setQuery}
      onSelectionChange={(id) => {
        if (id && !NON_NOTE_ID.test(id)) load(id);
      }}
      searchBarPlaceholder={
        dailyOnly
          ? "Daily Note：输入日期（上周 / 10月3日）或关键词过滤"
          : "搜索笔记 · 昨天 / 上周 / 10月3日 看时间线 · 「日记」看 Daily Note"
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

      {view?.kind === "daily" && renderDaily(dailyShown)}

      {!isLoading && !hasItems && view && (
        <List.EmptyView icon={Icon.MagnifyingGlass} title={emptyTitle} description={emptyDescription} />
      )}
    </List>
  );
}
