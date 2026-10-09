import { getNoteDetail } from "./api";
import { FocusSummary, formatMinutes } from "./dida-focus";
import { fetchTaskState } from "./dida-tasks";
import { editSections, loadProjectHomes, loadTaskNotes, noteUrl, stepProgress } from "./task-notes";
import { formatDate } from "./utils";
import { projectTerms, WatchItem } from "./watchlist";

/**
 * 项目主页自动汇总（防弹笔记法的「整体视角」）：
 * 把每个成果的状态、步骤进度、近 7 天专注，以及项目的下一步，写进项目主页笔记的两个小节。
 * 全部是精确读取（任务状态 / `- [x]` 计数 / 专注记录），没有任何猜测。
 */
export async function refreshProjectSummary(item: WatchItem, focus?: FocusSummary): Promise<void> {
  const homeId = (await loadProjectHomes())[item.keyword];
  if (!homeId) throw new Error("还没有项目主页笔记");

  const terms = projectTerms(item).map((t) => t.toLowerCase());
  const entries = Object.entries(await loadTaskNotes())
    .filter(([, r]) => r.project && terms.includes(r.project.toLowerCase()))
    .sort((a, b) => b[1].createdAt - a[1].createdAt)
    .slice(0, 15);

  let open = 0;
  let delivered = 0;
  let weekMin = 0;
  const lines: string[] = [];
  for (const [taskKey, ref] of entries) {
    const taskId = taskKey.startsWith("dida:") ? taskKey.slice(5) : "";
    const [state, detail] = await Promise.all([
      taskId ? fetchTaskState(taskId) : Promise.resolve("unknown" as const),
      getNoteDetail(ref.noteId).catch(() => null),
    ]);
    const progress = detail ? stepProgress(detail.content ?? detail.body ?? "") : null;
    const min = taskId ? (focus?.byTask[taskId]?.weekMin ?? 0) : 0;
    weekMin += min;
    if (state === "done") delivered++;
    else open++;

    const parts = [state === "done" ? "已交付" : state === "open" ? "进行中" : "状态未知"];
    if (progress) parts.push(`步骤 ${progress.done}/${progress.total}`);
    if (min > 0) parts.push(`近 7 天专注 ${formatMinutes(min)}`);
    lines.push(`- [${ref.deliverable}](${noteUrl(ref.noteId)}) · ${parts.join(" · ")}`);
  }

  const status = [
    `更新于 ${formatDate(new Date())}`,
    `- 下一步：${item.next || "（还没写，在 Todos 的项目上按 ⌘E 设置）"}`,
    `- 成果：进行中 ${open} · 已交付 ${delivered}`,
    `- 近 7 天专注（成果相关任务）：${weekMin > 0 ? formatMinutes(weekMin) : "无"}`,
  ].join("\n");

  await editSections(homeId, [
    ["任务笔记（自动汇总）", lines.join("\n") || "（还没有任务笔记）"],
    ["项目状态（自动汇总）", status],
  ]);
}
