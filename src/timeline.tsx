import { Action, ActionPanel, Color, Icon, List, showToast, Toast } from "@raycast/api";
import { useCallback, useEffect, useMemo, useState } from "react";
import { getNoteId, getNotesInRange, listTodos, NoteInfo, TodoItem, updateTodos } from "./api";
import { NoteDetailView } from "./note-detail-view";
import { lastDayOf, parseRange, TimeRange, weekdayName } from "./time-range";
import { formatDate, truncate } from "./utils";

interface DayBucket {
  date: string; // YYYY-MM-DD
  title: string; // 2026-10-08 周四
  notes: NoteInfo[];
  todos: TodoItem[];
}

interface TimelineData {
  range: TimeRange;
  days: DayBucket[];
  noteCount: number;
  todoDone: number;
  todoTotal: number;
  truncated: boolean;
}

function localDay(iso?: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "" : formatDate(d);
}

function localHHmm(iso?: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return `${d.getHours().toString().padStart(2, "0")}:${d.getMinutes().toString().padStart(2, "0")}`;
}

async function loadTimeline(range: TimeRange): Promise<TimelineData> {
  const from = formatDate(range.start);
  const to = formatDate(lastDayOf(range));

  const [{ notes, truncated }, open, done] = await Promise.all([
    getNotesInRange(range.start, range.end),
    listTodos({ isCompleted: false, dateFrom: from, dateTo: to, limit: 200 }),
    listTodos({ isCompleted: true, dateFrom: from, dateTo: to, limit: 200 }),
  ]);

  // 无日期待办不属于任何一天；区间外的也丢弃（接口对日期过滤的边界行为未明确，这里再兜底过滤一次）
  const todos = [...open, ...done].filter((t) => t.date && t.date >= from && t.date <= to);

  const map = new Map<string, DayBucket>();
  const bucket = (date: string): DayBucket => {
    let b = map.get(date);
    if (!b) {
      const d = new Date(`${date}T00:00:00`);
      b = { date, title: `${date} ${weekdayName(d)}`, notes: [], todos: [] };
      map.set(date, b);
    }
    return b;
  };

  for (const n of notes) {
    const date = localDay(n.created_at);
    if (date) bucket(date).notes.push(n);
  }
  for (const t of todos) bucket(t.date as string).todos.push(t);

  const days = [...map.values()].sort((a, b) => b.date.localeCompare(a.date));
  days.forEach((d) => d.todos.sort((a, b) => (a.time ?? "99:99").localeCompare(b.time ?? "99:99")));

  return {
    range,
    days,
    noteCount: notes.length,
    todoDone: todos.filter((t) => t.is_completed).length,
    todoTotal: todos.length,
    truncated,
  };
}

/** 生成可直接贴进日报/周报的 Markdown */
function buildReport(data: TimelineData): string {
  const lines = [
    `# ${data.range.label} 回顾`,
    "",
    `> ${data.noteCount} 条笔记 · 待办完成 ${data.todoDone}/${data.todoTotal}`,
  ];

  for (const day of data.days) {
    lines.push("", `## ${day.title}`);
    if (day.notes.length > 0) {
      lines.push("", "**笔记**", "");
      // 同一天内按时间正序更符合阅读习惯
      [...day.notes].reverse().forEach((n) => {
        const time = localHHmm(n.created_at);
        const summary = n.summary ? ` — ${truncate(n.summary.replace(/\s+/g, " "), 80)}` : "";
        lines.push(`- ${time ? `${time} ` : ""}**${n.title}**${summary}`);
      });
    }
    if (day.todos.length > 0) {
      lines.push("", "**待办**", "");
      day.todos.forEach((t) => {
        lines.push(`- [${t.is_completed ? "x" : " "}] ${t.content}${t.time ? `（${t.time}）` : ""}`);
      });
    }
  }
  return lines.join("\n");
}

export default function Command() {
  const [query, setQuery] = useState("");
  const [data, setData] = useState<TimelineData | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [invalid, setInvalid] = useState(false);

  const load = useCallback(async (text: string) => {
    const range = parseRange(text);
    if (!range) {
      setInvalid(true);
      setData(null);
      setIsLoading(false);
      return;
    }
    setInvalid(false);
    setIsLoading(true);
    try {
      setData(await loadTimeline(range));
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "加载失败",
        message: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    const timer = setTimeout(() => load(query), 400);
    return () => clearTimeout(timer);
  }, [query, load]);

  const report = useMemo(() => (data ? buildReport(data) : ""), [data]);

  async function toggle(todo: TodoItem) {
    try {
      await updateTodos([{ todo_id: todo.id, is_completed: !todo.is_completed }]);
      await load(query);
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "操作失败",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  const copyReport = (
    <Action.CopyToClipboard
      title="复制为 Markdown 回顾"
      icon={Icon.Clipboard}
      content={report}
      shortcut={{ modifiers: ["cmd"], key: "return" }}
    />
  );

  return (
    <List
      isLoading={isLoading}
      filtering={false}
      onSearchTextChange={setQuery}
      searchBarPlaceholder="时间范围：昨天 / 上周 / 本月 / 10月3日 / 最近14天 / 10月1日到10月7日（留空=最近7天）"
      throttle
    >
      {data && data.days.length > 0 && (
        <List.Section title="概览">
          <List.Item
            title={data.range.label}
            subtitle={`${data.noteCount} 条笔记 · 待办 ${data.todoDone}/${data.todoTotal} 完成`}
            icon={{ source: Icon.Calendar, tintColor: Color.Blue }}
            accessories={[
              ...(data.range.clamped ? [{ tag: { value: "已截断至 62 天", color: Color.Orange } }] : []),
              ...(data.truncated ? [{ tag: { value: "部分时段笔记过多", color: Color.Orange } }] : []),
            ]}
            actions={<ActionPanel>{copyReport}</ActionPanel>}
          />
        </List.Section>
      )}

      {data?.days.map((day) => (
        <List.Section
          key={day.date}
          title={day.title}
          subtitle={`${day.notes.length} 笔记${day.todos.length ? ` · ${day.todos.length} 待办` : ""}`}
        >
          {day.notes.map((note) => {
            const noteId = getNoteId(note);
            return (
              <List.Item
                key={`n-${noteId}`}
                title={note.title}
                subtitle={note.summary ? truncate(note.summary.replace(/\s+/g, " "), 70) : undefined}
                icon={Icon.Document}
                accessories={[{ text: localHHmm(note.created_at) }]}
                actions={
                  <ActionPanel>
                    <Action.Push
                      title="查看全文"
                      icon={Icon.Eye}
                      target={<NoteDetailView noteId={noteId} title={note.title} summary={note.summary} />}
                    />
                    {copyReport}
                    {note.summary && (
                      <Action.CopyToClipboard
                        title="复制摘要"
                        content={note.summary}
                        shortcut={{ modifiers: ["cmd", "opt"], key: "c" }}
                      />
                    )}
                  </ActionPanel>
                }
              />
            );
          })}
          {day.todos.map((todo) => (
            <List.Item
              key={`t-${todo.id}`}
              title={todo.content}
              icon={
                todo.is_completed
                  ? { source: Icon.CheckCircle, tintColor: Color.Green }
                  : { source: Icon.Circle, tintColor: Color.SecondaryText }
              }
              accessories={[...(todo.time ? [{ tag: { value: todo.time, color: Color.Blue } }] : []), { text: "待办" }]}
              actions={
                <ActionPanel>
                  <Action
                    title={todo.is_completed ? "恢复为未完成" : "标记完成"}
                    icon={todo.is_completed ? Icon.Circle : Icon.CheckCircle}
                    onAction={() => toggle(todo)}
                  />
                  {copyReport}
                </ActionPanel>
              }
            />
          ))}
        </List.Section>
      ))}

      {!isLoading && (invalid || (data && data.days.length === 0)) && (
        <List.EmptyView
          icon={Icon.Calendar}
          title={invalid ? "无法识别这个时间范围" : `${data?.range.label ?? "这段时间"} 没有记录`}
          description={
            invalid
              ? "试试：昨天、上周、本月、周三、上周三、10月3日、最近14天、10月1日到10月7日"
              : "换个时间范围看看，或者现在就记一条"
          }
        />
      )}
    </List>
  );
}
