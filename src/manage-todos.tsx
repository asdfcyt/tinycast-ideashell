import { Action, ActionPanel, Color, Form, Icon, List, showToast, Toast, useNavigation } from "@raycast/api";
import { useCallback, useEffect, useMemo, useState } from "react";
import { createTodos, listTodos, TodoItem, updateTodos } from "./api";
import { parseDateTimeFields, parseTodoInput } from "./todo-parse";
import { formatDate } from "./utils";

const WEEKDAYS = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

function addDays(date: Date, days: number): string {
  const d = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  d.setDate(d.getDate() + days);
  return formatDate(d);
}

function dateLabel(date: string): string {
  const d = new Date(`${date}T00:00:00`);
  return Number.isNaN(d.getTime()) ? date : `${date} ${WEEKDAYS[d.getDay()]}`;
}

function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

function byDateTime(a: TodoItem, b: TodoItem): number {
  return `${a.date ?? ""} ${a.time ?? ""}`.localeCompare(`${b.date ?? ""} ${b.time ?? ""}`);
}

interface Group {
  key: string;
  title: string;
  items: TodoItem[];
}

function buildGroups(todos: TodoItem[], done: TodoItem[]): Group[] {
  const now = new Date();
  const today = formatDate(now);
  const tomorrow = addDays(now, 1);

  const groups: Group[] = [];
  const push = (key: string, title: string, items: TodoItem[]) => {
    if (items.length > 0) groups.push({ key, title, items });
  };

  const sorted = [...todos].sort(byDateTime);
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
  push(
    "tomorrow",
    `明天 · ${dateLabel(tomorrow)}`,
    sorted.filter((t) => t.date === tomorrow),
  );

  const later = sorted.filter((t) => t.date && t.date > tomorrow);
  const laterDates = [...new Set(later.map((t) => t.date as string))];
  laterDates.forEach((d) =>
    push(
      `d-${d}`,
      dateLabel(d),
      later.filter((t) => t.date === d),
    ),
  );

  push(
    "undated",
    "无日期",
    sorted.filter((t) => !t.date),
  );
  push("done", "最近已完成", done);
  return groups;
}

export default function Command() {
  const [todos, setTodos] = useState<TodoItem[]>([]);
  const [done, setDone] = useState<TodoItem[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchText, setSearchText] = useState("");

  const reload = useCallback(async () => {
    setIsLoading(true);
    try {
      const [open, completed] = await Promise.all([
        listTodos({ isCompleted: false, limit: 200 }),
        listTodos({ isCompleted: true, limit: 20 }),
      ]);
      setTodos(open);
      setDone(completed);
    } catch (e) {
      await showToast({ style: Toast.Style.Failure, title: "加载待办失败", message: errorMessage(e) });
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  async function toggle(todo: TodoItem) {
    const completing = !todo.is_completed;
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: completing ? "标记完成..." : "恢复为未完成...",
    });
    try {
      await updateTodos([{ todo_id: todo.id, is_completed: completing }]);
      toast.style = Toast.Style.Success;
      toast.title = completing ? "已完成" : "已恢复为未完成";
      await reload();
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = "操作失败";
      toast.message = errorMessage(e);
    }
  }

  async function createFromSearch() {
    const text = searchText.trim();
    if (!text) return;
    const { content, date, time } = parseTodoInput(text);
    const toast = await showToast({ style: Toast.Style.Animated, title: "正在创建待办..." });
    try {
      await createTodos([{ content, ...(date ? { date } : {}), ...(time ? { time } : {}) }]);
      toast.style = Toast.Style.Success;
      toast.title = `已添加：${content}`;
      setSearchText("");
      await reload();
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = "创建失败";
      toast.message = errorMessage(e);
    }
  }

  const groups = useMemo(() => buildGroups(todos, done), [todos, done]);

  const createActions = (
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
        target={<TodoForm onDone={reload} />}
      />
    </>
  );

  return (
    <List
      isLoading={isLoading}
      searchBarPlaceholder="搜索待办；输入「明天 15:00 开会」后 ⌘↵ 直接创建"
      onSearchTextChange={setSearchText}
    >
      {groups.map((group) => (
        <List.Section key={group.key} title={group.title} subtitle={`${group.items.length}`}>
          {group.items.map((todo) => {
            const isOverdue = group.key === "overdue";
            return (
              <List.Item
                key={todo.id}
                title={todo.content}
                icon={
                  todo.is_completed
                    ? { source: Icon.CheckCircle, tintColor: Color.Green }
                    : { source: Icon.Circle, tintColor: isOverdue ? Color.Red : Color.SecondaryText }
                }
                accessories={[
                  ...(todo.time ? [{ tag: { value: todo.time, color: isOverdue ? Color.Red : Color.Blue } }] : []),
                  ...(todo.date && (group.key === "overdue" || group.key === "done") ? [{ text: todo.date }] : []),
                ]}
                actions={
                  <ActionPanel>
                    <Action
                      title={todo.is_completed ? "恢复为未完成" : "标记完成"}
                      icon={todo.is_completed ? Icon.Circle : Icon.CheckCircle}
                      onAction={() => toggle(todo)}
                    />
                    <Action.Push
                      title="编辑待办"
                      icon={Icon.Pencil}
                      shortcut={{ modifiers: ["cmd"], key: "e" }}
                      target={<TodoForm todo={todo} onDone={reload} />}
                    />
                    {createActions}
                    <Action.CopyToClipboard
                      title="复制内容"
                      content={todo.content}
                      shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
                    />
                    <Action
                      title="刷新"
                      icon={Icon.ArrowClockwise}
                      shortcut={{ modifiers: ["cmd"], key: "r" }}
                      onAction={reload}
                    />
                  </ActionPanel>
                }
              />
            );
          })}
        </List.Section>
      ))}
      {/* 仅在没有可见条目（无待办，或搜索无匹配）时才会显示 */}
      {!isLoading && (
        <List.EmptyView
          title={searchText.trim() ? "没有匹配的待办" : "没有待办"}
          description={
            searchText.trim()
              ? "按 ⌘↵ 用输入的文字直接创建待办（可含日期时间）"
              : "在搜索栏输入内容后按 ⌘↵ 创建，或按 ⌘N 新建"
          }
          icon={Icon.CheckCircle}
          actions={<ActionPanel>{createActions}</ActionPanel>}
        />
      )}
    </List>
  );
}

function TodoForm({ todo, onDone }: { todo?: TodoItem; onDone: () => Promise<void> | void }) {
  const { pop } = useNavigation();
  const editing = !!todo;

  async function handleSubmit(values: { content: string; date: string; time: string }) {
    const content = values.content.trim();
    if (!content) {
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

    const toast = await showToast({ style: Toast.Style.Animated, title: editing ? "正在保存..." : "正在创建..." });
    try {
      if (todo) {
        await updateTodos([
          {
            todo_id: todo.id,
            ...(content !== todo.content ? { content } : {}),
            ...(when.date && when.date !== todo.date ? { date: when.date } : {}),
            ...(when.time && when.time !== todo.time ? { time: when.time } : {}),
          },
        ]);
      } else {
        await createTodos([
          { content, ...(when.date ? { date: when.date } : {}), ...(when.time ? { time: when.time } : {}) },
        ]);
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
      navigationTitle={editing ? "编辑待办" : "新建待办"}
      actions={
        <ActionPanel>
          <Action.SubmitForm title={editing ? "保存" : "创建"} onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField id="content" title="内容" placeholder="要做什么？" defaultValue={todo?.content ?? ""} />
      <Form.TextField
        id="date"
        title="日期"
        placeholder="如 2026-10-09 / 明天 / 周五 / 10月9日"
        defaultValue={todo?.date ?? ""}
        info={editing ? "接口不支持清除日期，留空表示保持不变" : "留空表示无日期"}
      />
      <Form.TextField
        id="time"
        title="时间"
        placeholder="如 15:30 / 下午3点半"
        defaultValue={todo?.time ?? ""}
        info={editing ? "接口不支持清除时间，留空表示保持不变" : "留空表示无具体时间"}
      />
    </Form>
  );
}
