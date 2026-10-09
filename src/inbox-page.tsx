import {
  Action,
  ActionPanel,
  Alert,
  Color,
  confirmAlert,
  Form,
  Icon,
  List,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useState } from "react";
import { deleteDidaTask, didaTaskUrl } from "./dida-tasks";
import { TaskNoteForm } from "./project-forms";
import { TodoRow } from "./todo-data";
import { completeRow, patchRow } from "./todo-ops";
import { parseDateTimeFields } from "./todo-parse";
import { WatchItem } from "./watchlist";

/**
 * 收集箱整理：Todos 不显示没有日期的任务，在这里逐条处理——
 * 定日期（之后会出现在列表里）/ 归入项目 / 写交付成果 / 完成 / 删除。
 */

const errMsg = (e: unknown) => (e instanceof Error ? e.message : String(e));

function DateForm({ row, onDone }: { row: TodoRow; onDone: () => void }) {
  const { pop } = useNavigation();

  async function handleSubmit(values: { date: string; time: string; important: boolean }) {
    const when = parseDateTimeFields(values.date, values.time);
    if (!when.ok || !when.date) {
      await showToast({
        style: Toast.Style.Failure,
        title: "请填写日期",
        message: "例：今天、明天、周五、2026-10-12；时间可选，如 15:30",
      });
      return;
    }
    const toast = await showToast({ style: Toast.Style.Animated, title: "正在保存..." });
    try {
      await patchRow(row, { date: when.date, time: when.time, ...(values.important ? { priority: 5 } : {}) });
      toast.style = Toast.Style.Success;
      toast.title = `已安排到 ${when.date}${when.time ? ` ${when.time}` : ""}`;
      onDone();
      pop();
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = "保存失败";
      toast.message = errMsg(e);
    }
  }

  return (
    <Form
      navigationTitle="定日期"
      actions={
        <ActionPanel>
          <Action.SubmitForm title="保存" icon={Icon.Check} onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.Description title="任务" text={row.title} />
      <Form.TextField id="date" title="日期" placeholder="今天 / 明天 / 周五 / 2026-10-12" autoFocus />
      <Form.TextField id="time" title="时间" placeholder="可选，如 15:30（不填则当天 9:00 提醒）" />
      <Form.Checkbox id="important" label="重要（高优先级）" defaultValue={false} />
    </Form>
  );
}

export function InboxPage({
  rows,
  projects,
  onChanged,
}: {
  rows: TodoRow[];
  projects: WatchItem[];
  onChanged: () => void;
}) {
  const [items, setItems] = useState(rows);
  const [busy, setBusy] = useState(false);

  const drop = (key: string) => {
    setItems((prev) => prev.filter((r) => r.key !== key));
    onChanged();
  };

  async function run(title: string, ok: string, row: TodoRow, fn: () => Promise<void>, remove = true) {
    setBusy(true);
    const toast = await showToast({ style: Toast.Style.Animated, title });
    try {
      await fn();
      toast.style = Toast.Style.Success;
      toast.title = ok;
      if (remove) drop(row.key);
      else onChanged();
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = "操作失败";
      toast.message = errMsg(e);
    } finally {
      setBusy(false);
    }
  }

  async function remove(row: TodoRow) {
    if (
      await confirmAlert({
        title: "删除这个任务？",
        message: row.title,
        primaryAction: { title: "删除", style: Alert.ActionStyle.Destructive },
      })
    ) {
      await run("正在删除...", "已删除", row, () => deleteDidaTask(row));
    }
  }

  return (
    <List
      isLoading={busy}
      isShowingDetail
      navigationTitle="整理收集箱"
      searchBarPlaceholder="没有日期的任务：定日期 / 归入项目 / 写交付成果 / 完成 / 删除"
    >
      {items.length === 0 ? (
        <List.EmptyView title="收集箱已清空" description="没有需要整理的无日期任务" icon={Icon.CheckCircle} />
      ) : (
        <List.Section title="没有日期的任务" subtitle={`${items.length}`}>
          {items.map((row) => (
            <List.Item
              key={row.key}
              id={row.key}
              title={row.title}
              icon={{ source: Icon.Circle, tintColor: Color.SecondaryText }}
              accessories={row.priority >= 3 ? [{ icon: { source: Icon.Star, tintColor: Color.Orange } }] : []}
              detail={
                <List.Item.Detail
                  markdown={`# ${row.title}\n\n${row.content ? `${row.content}\n\n` : ""}还没有日期。按回车**定日期**后，它会出现在 Todos 的对应分组。`}
                  metadata={
                    <List.Item.Detail.Metadata>
                      <List.Item.Detail.Metadata.Label
                        title="来源"
                        text={
                          row.source === "dida" ? `滴答清单${row.listName ? ` · ${row.listName}` : ""}` : "闪念贝壳"
                        }
                      />
                      <List.Item.Detail.Metadata.Label title="标签" text={row.tags.join("、") || "无"} />
                    </List.Item.Detail.Metadata>
                  }
                />
              }
              actions={
                <ActionPanel>
                  <Action.Push
                    title="定日期"
                    icon={Icon.Calendar}
                    target={<DateForm row={row} onDone={() => drop(row.key)} />}
                  />
                  {projects.length > 0 && (
                    <ActionPanel.Submenu title="归入项目" icon={Icon.Pin} shortcut={{ modifiers: ["cmd"], key: "j" }}>
                      {projects.map((p) => (
                        <Action
                          key={p.keyword}
                          title={p.keyword}
                          onAction={() =>
                            run(
                              "正在归入项目...",
                              `已归入「${p.keyword}」`,
                              row,
                              () =>
                                row.source === "dida"
                                  ? patchRow(row, { tags: [...new Set([...row.tags, p.keyword])] })
                                  : patchRow(row, { title: `${row.title} #${p.keyword}` }),
                              false,
                            )
                          }
                        />
                      ))}
                    </ActionPanel.Submenu>
                  )}
                  <Action.Push
                    title="写交付成果（创建任务笔记）"
                    icon={Icon.Document}
                    shortcut={{ modifiers: ["cmd", "shift"], key: "j" }}
                    target={<TaskNoteForm row={row} onDone={() => onChanged()} />}
                  />
                  <Action
                    title="完成"
                    icon={Icon.CheckCircle}
                    shortcut={{ modifiers: ["cmd"], key: "return" }}
                    onAction={() => run("标记完成...", "已完成", row, () => completeRow(row))}
                  />
                  {row.source === "dida" && (
                    <>
                      <Action
                        title="删除任务"
                        icon={Icon.Trash}
                        style={Action.Style.Destructive}
                        shortcut={{ modifiers: ["ctrl"], key: "x" }}
                        onAction={() => remove(row)}
                      />
                      <Action.OpenInBrowser
                        title="在滴答清单中打开"
                        url={didaTaskUrl(row)}
                        shortcut={{ modifiers: ["cmd"], key: "o" }}
                      />
                    </>
                  )}
                </ActionPanel>
              }
            />
          ))}
        </List.Section>
      )}
    </List>
  );
}
