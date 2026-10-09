import { Action, ActionPanel, Color, Icon, List, showToast, Toast } from "@raycast/api";
import { useEffect, useState } from "react";
import { didaTaskUrl } from "./dida-tasks";
import { NotesBrowser } from "./notes";
import { NextForm, ProgressForm, syncProjectHome } from "./project-forms";
import { createProjectHome, loadProjectHomes, loadTaskNotes, noteUrl, taskNoteLinks, TaskNoteRef } from "./task-notes";
import { TodoRow } from "./todo-data";
import { projectTerms, WatchItem, WatchStats } from "./watchlist";
import { WatchLogForm } from "./watch-log";

/**
 * 项目主页（防弹笔记法的「项目主控台」）：
 * 下一步、要交付的成果（任务笔记）、滴答里的相关任务、资料与最近提及，汇在一页。
 */
const NO_NOTES_MD = `# 任务笔记

一个任务，一条笔记。笔记的单位是**要交付的成果**（如「完成论文初稿」），不是要做的事情（如「阅读文献」）。

在 Todos 里选中一个属于本项目的任务，按 \`⌘J\` 创建，笔记会自动汇到这里。
`;

const NO_TASKS_MD = `# 相关任务

逾期、今天起 7 天内，标题或标签里含项目关键词（或项目标签）的任务会显示在这里。
`;

export function ProjectPage({
  item,
  stats,
  rows,
  onChanged,
}: {
  item: WatchItem;
  stats?: WatchStats;
  rows: TodoRow[];
  onChanged: () => void;
}) {
  const [homeId, setHomeId] = useState<string | undefined>();
  const [refs, setRefs] = useState<Array<TaskNoteRef & { taskKey: string }>>([]);
  const [next, setNext] = useState(item.next);
  const [busy, setBusy] = useState(false);

  async function reload() {
    const homes = await loadProjectHomes();
    setHomeId(homes[item.keyword]);
    const terms = projectTerms(item).map((t) => t.toLowerCase());
    const all = await loadTaskNotes();
    setRefs(
      Object.entries(all)
        .filter(([, r]) => r.project && terms.includes(r.project.toLowerCase()))
        .map(([taskKey, r]) => ({ ...r, taskKey }))
        .sort((a, b) => b.createdAt - a.createdAt),
    );
  }
  useEffect(() => {
    reload();
  }, []);

  async function createHome() {
    setBusy(true);
    const toast = await showToast({ style: Toast.Style.Animated, title: "正在创建项目主页笔记..." });
    try {
      const id = await createProjectHome(item.keyword, item.tags, taskNoteLinks(refs));
      setHomeId(id);
      toast.style = Toast.Style.Success;
      toast.title = "已创建项目主页笔记";
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = "创建失败";
      toast.message = e instanceof Error ? e.message : String(e);
    } finally {
      setBusy(false);
    }
  }

  async function refreshHome() {
    setBusy(true);
    try {
      await syncProjectHome(item.keyword);
      await showToast({ style: Toast.Style.Success, title: "已更新项目主页里的任务笔记汇总" });
    } catch (e) {
      await showToast({
        style: Toast.Style.Failure,
        title: "更新失败",
        message: e instanceof Error ? e.message : String(e),
      });
    } finally {
      setBusy(false);
    }
  }

  const nextAction = (
    <Action.Push
      title="设置下一步"
      icon={Icon.Flag}
      shortcut={{ modifiers: ["cmd"], key: "e" }}
      target={
        <NextForm
          keyword={item.keyword}
          current={next}
          onDone={(value) => {
            setNext(value);
            onChanged();
          }}
        />
      }
    />
  );
  const logAction = (
    <Action.Push
      title={`记一条「${item.keyword}」`}
      icon={Icon.Pencil}
      shortcut={{ modifiers: ["cmd"], key: "l" }}
      target={<WatchLogForm keyword={item.keyword} />}
    />
  );

  return (
    <List isLoading={busy} isShowingDetail navigationTitle={`${item.keyword} · 项目主页`}>
      <List.Section title="项目主页笔记">
        <List.Item
          id="home"
          title={homeId ? "项目主页笔记" : "创建项目主页笔记"}
          subtitle={homeId ? "目标 · 交付成果 · 任务笔记汇总 · 资料" : "把项目的所有资料和任务汇到一条笔记里"}
          icon={{ source: Icon.House, tintColor: homeId ? Color.Green : Color.SecondaryText }}
          detail={
            <List.Item.Detail
              markdown={`# 项目主页\n\n项目的**总控台**：一条笔记里放这个项目的目标、要交付的成果、所有任务笔记的链接、资料链接、里程碑与复盘。\n\n${
                homeId
                  ? "已创建。新增任务笔记后，按 `⌘R` 可把链接汇总更新到主页笔记里。"
                  : "按回车创建，会生成：目标 / 交付成果 / 任务笔记（自动汇总）/ 资料与链接 / 里程碑与进展 / 复盘与经验。"
              }`}
            />
          }
          actions={
            <ActionPanel>
              {homeId ? (
                <>
                  <Action.OpenInBrowser title="打开项目主页笔记" url={noteUrl(homeId)} />
                  <Action
                    title="更新任务笔记汇总"
                    icon={Icon.ArrowClockwise}
                    shortcut={{ modifiers: ["cmd"], key: "r" }}
                    onAction={refreshHome}
                  />
                </>
              ) : (
                <Action title="创建项目主页笔记" icon={Icon.Plus} onAction={createHome} />
              )}
              {nextAction}
              {logAction}
            </ActionPanel>
          }
        />
        <List.Item
          id="next"
          title="下一步"
          subtitle={next || item.next || "还没写，按回车设置"}
          icon={{ source: Icon.Flag, tintColor: Color.Orange }}
          detail={
            <List.Item.Detail
              markdown={`# 下一步\n\n${next || item.next || "_写成能直接开始的动作，例如「临《洛神赋》第三段，写 5 遍」_"}`}
            />
          }
          actions={<ActionPanel>{nextAction}</ActionPanel>}
        />
      </List.Section>

      <List.Section title="要交付的成果（任务笔记）" subtitle={`${refs.length}`}>
        {refs.length === 0 ? (
          <List.Item
            id="no-notes"
            title="还没有任务笔记"
            subtitle="在 Todos 的任务上按 ⌘J 创建"
            icon={{ source: Icon.Document, tintColor: Color.SecondaryText }}
            detail={<List.Item.Detail markdown={NO_NOTES_MD} />}
          />
        ) : (
          refs.map((r) => (
            <List.Item
              key={r.taskKey}
              id={`note-${r.noteId}`}
              title={r.deliverable}
              icon={{ source: Icon.Document, tintColor: Color.Blue }}
              accessories={[{ text: new Date(r.createdAt).toISOString().slice(0, 10) }]}
              detail={<List.Item.Detail markdown={`# ${r.deliverable}\n\n任务笔记：${noteUrl(r.noteId)}`} />}
              actions={
                <ActionPanel>
                  <Action.OpenInBrowser title="打开任务笔记" url={noteUrl(r.noteId)} />
                  <Action.Push
                    title="记一条进展"
                    icon={Icon.Pencil}
                    shortcut={{ modifiers: ["cmd"], key: "l" }}
                    target={<ProgressForm noteId={r.noteId} title={r.deliverable} />}
                  />
                </ActionPanel>
              }
            />
          ))
        )}
      </List.Section>

      <List.Section title="滴答清单里的相关任务" subtitle={`${rows.length}`}>
        {rows.length === 0 ? (
          <List.Item
            id="no-tasks"
            title="近期没有相关任务"
            subtitle="任务标题或标签含项目关键词即归入"
            icon={{ source: Icon.Circle, tintColor: Color.SecondaryText }}
            detail={<List.Item.Detail markdown={NO_TASKS_MD} />}
          />
        ) : (
          rows.map((r) => (
            <List.Item
              key={r.key}
              id={r.key}
              title={r.title}
              icon={{ source: Icon.Circle, tintColor: Color.SecondaryText }}
              accessories={[...(r.time ? [{ tag: r.time }] : []), ...(r.date ? [{ text: r.date }] : [])]}
              detail={<List.Item.Detail markdown={`# ${r.title}\n\n${r.date ?? "无日期"} ${r.time ?? ""}`} />}
              actions={
                <ActionPanel>
                  {r.source === "dida" && <Action.OpenInBrowser title="在滴答清单中打开" url={didaTaskUrl(r)} />}
                  <Action.CopyToClipboard title="复制任务标题" content={r.title} />
                </ActionPanel>
              }
            />
          ))
        )}
      </List.Section>

      <List.Section title="资料与最近提及">
        <List.Item
          id="brief"
          title="最近提及与简报"
          subtitle={stats?.lastDay ? `最近一次 ${stats.lastDay} · 近 30 天 ${stats.count30} 次` : "统计中…或还没有记录"}
          icon={{ source: Icon.Clock, tintColor: Color.Purple }}
          detail={<List.Item.Detail markdown={stats?.doc.markdown ?? "_统计中…_"} />}
          actions={
            <ActionPanel>
              <Action.Push title="查看档案" icon={Icon.Person} target={<NotesBrowser dossierOf={item.keyword} />} />
              {stats && <Action.CopyToClipboard title="复制简报（Markdown）" content={stats.doc.copy} />}
              {logAction}
            </ActionPanel>
          }
        />
      </List.Section>
    </List>
  );
}
