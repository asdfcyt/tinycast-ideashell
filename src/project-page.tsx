import { Action, ActionPanel, Color, Icon, List, showToast, Toast } from "@raycast/api";
import { useEffect, useState } from "react";
import { getNoteDetail } from "./api";
import { FocusSummary, formatMinutes } from "./dida-focus";
import { didaTaskUrl } from "./dida-tasks";
import { NotesBrowser } from "./notes";
import { NextForm, ProgressForm } from "./project-forms";
import { refreshProjectSummary } from "./project-summary";
import {
  createProjectHome,
  displayNote,
  loadProjectHomes,
  loadTaskNotes,
  noteUrl,
  taskNoteLinks,
  TaskNoteRef,
} from "./task-notes";
import { TodoRow } from "./todo-data";
import { projectTerms, WatchItem, WatchStats } from "./watchlist";
import { WatchLogForm } from "./watch-log";

/**
 * 项目主页（防弹笔记法的「项目主控台」）：
 * 下一步、要交付的成果（任务笔记）、滴答里的相关任务、资料与最近提及，汇在一页。
 */
const HOME_INTRO_MD = `# 项目主页

项目的**总控台**：一条笔记里放这个项目的目标、要交付的成果、所有任务笔记的链接、资料链接、里程碑与复盘。

按回车创建，会生成这些小节：

- 目标
- 交付成果
- 任务笔记（自动汇总）
- 资料与链接
- 里程碑与进展
- 复盘与经验
`;

const NO_NOTES_MD = `# 任务笔记

一个任务，一条笔记。笔记的单位是**要交付的成果**（如「完成论文初稿」），不是要做的事情（如「阅读文献」）。

在 Todos 里选中一个属于本项目的任务，按 \`⌘J\` 创建，笔记会自动汇到这里。
`;

const NO_TASKS_MD = `# 相关任务

逾期、今天起 7 天内，标题或标签里含项目关键词（或项目标签）的任务会显示在这里。
`;

/** 笔记正文太长时截断，避免详情页过长 */
function clip(raw: string, max = 2500): string {
  const text = displayNote(raw);
  return text.length > max ? `${text.slice(0, max).trimEnd()}\n\n…（后面的内容请打开笔记查看）` : text;
}

export function ProjectPage({
  item,
  stats,
  rows,
  focus,
  onChanged,
}: {
  item: WatchItem;
  stats?: WatchStats;
  rows: TodoRow[];
  focus?: FocusSummary;
  onChanged: () => void;
}) {
  const [homeId, setHomeId] = useState<string | undefined>();
  const [refs, setRefs] = useState<Array<TaskNoteRef & { taskKey: string }>>([]);
  const [next, setNext] = useState(item.next);
  const [busy, setBusy] = useState(false);
  const [homeText, setHomeText] = useState<string | undefined>();
  const [noteTexts, setNoteTexts] = useState<Record<string, string>>({});

  async function loadText(noteId: string): Promise<string> {
    try {
      const d = await getNoteDetail(noteId);
      return (d.content ?? d.body ?? "").trim();
    } catch {
      return "";
    }
  }

  async function reload() {
    const homes = await loadProjectHomes();
    setHomeId(homes[item.keyword]);
    const terms = projectTerms(item).map((t) => t.toLowerCase());
    const all = await loadTaskNotes();
    const mine = Object.entries(all)
      .filter(([, r]) => r.project && terms.includes(r.project.toLowerCase()))
      .map(([taskKey, r]) => ({ ...r, taskKey }))
      .sort((a, b) => b.createdAt - a.createdAt);
    setRefs(mine);
    // 笔记正文在后台读取，读到一条显示一条
    if (homes[item.keyword]) loadText(homes[item.keyword]).then(setHomeText);
    mine
      .slice(0, 10)
      .forEach((r) => loadText(r.noteId).then((t) => setNoteTexts((prev) => ({ ...prev, [r.noteId]: t }))));
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
      loadText(id).then(setHomeText);
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
      await refreshProjectSummary(item, focus);
      if (homeId) setHomeText(await loadText(homeId));
      await showToast({ style: Toast.Style.Success, title: "已更新项目主页的自动汇总" });
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

  const noteMarkdown = (r: TaskNoteRef) => {
    const t = noteTexts[r.noteId];
    return t === undefined
      ? `# ${r.deliverable}\n\n_正在读取任务笔记…_`
      : `# ${r.deliverable}\n\n${clip(t || "（笔记内容为空）")}`;
  };

  const weekFocus = rows.reduce((sum, r) => sum + (focus?.byTask[r.id]?.weekMin ?? 0), 0);

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
      target={<WatchLogForm keyword={item.keyword} tags={item.tags} />}
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
              markdown={homeId ? (homeText ? clip(homeText) : "_正在读取项目主页笔记…_") : HOME_INTRO_MD}
            />
          }
          actions={
            <ActionPanel>
              {homeId ? (
                <>
                  <Action.OpenInBrowser title="打开项目主页笔记" url={noteUrl(homeId)} />
                  <Action
                    title="更新项目主页汇总（成果状态 / 进度 / 专注）"
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
              detail={<List.Item.Detail markdown={noteMarkdown(r)} />}
              actions={
                <ActionPanel>
                  <Action.OpenInBrowser title="打开任务笔记" url={noteUrl(r.noteId)} />
                  <Action.Push
                    title="记一条进展"
                    icon={Icon.Pencil}
                    shortcut={{ modifiers: ["cmd"], key: "l" }}
                    target={<ProgressForm noteId={r.noteId} title={r.deliverable} taskKey={r.taskKey} />}
                  />
                </ActionPanel>
              }
            />
          ))
        )}
      </List.Section>

      <List.Section
        title="滴答清单里的相关任务"
        subtitle={`${rows.length}${weekFocus > 0 ? ` · 近 7 天专注 ${formatMinutes(weekFocus)}` : ""}`}
      >
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
