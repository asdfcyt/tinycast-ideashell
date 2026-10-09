import { LocalStorage } from "@raycast/api";
import { createNote, getNoteDetail, updateNote } from "./api";
import { formatMinute, truncate } from "./utils";

/**
 * 任务笔记（防弹笔记法）：一个任务，一条笔记；笔记的单位是「要交付的成果」。
 * 项目主页笔记：把项目的所有任务笔记、资料、进展汇到一处。
 * 两者都只是普通的闪念贝壳笔记，本地只记「任务 ↔ 笔记 id」的对应关系，可丢弃重建。
 */

export interface TaskNoteRef {
  noteId: string;
  deliverable: string;
  project?: string;
  createdAt: number;
}

const TASK_NOTES_KEY = "task-notes-v1";
const PROJECT_HOME_KEY = "project-home-v1";

export const noteUrl = (noteId: string) =>
  `https://ideashell.site/boards/${noteId}`;

async function readMap<T>(key: string): Promise<Record<string, T>> {
  try {
    const raw = await LocalStorage.getItem<string>(key);
    return raw ? (JSON.parse(raw) as Record<string, T>) : {};
  } catch {
    return {};
  }
}

export const loadTaskNotes = () => readMap<TaskNoteRef>(TASK_NOTES_KEY);

export async function saveTaskNote(
  taskKey: string,
  ref: TaskNoteRef,
): Promise<void> {
  const map = await loadTaskNotes();
  map[taskKey] = ref;
  await LocalStorage.setItem(TASK_NOTES_KEY, JSON.stringify(map));
}

export const loadProjectHomes = () => readMap<string>(PROJECT_HOME_KEY);

export async function saveProjectHome(
  keyword: string,
  noteId: string,
): Promise<void> {
  const map = await loadProjectHomes();
  map[keyword] = noteId;
  await LocalStorage.setItem(PROJECT_HOME_KEY, JSON.stringify(map));
}

function noteIdOf(created: string): string {
  const m =
    created.match(/"note_id"\s*:\s*"([^"]+)"/) ??
    created.match(/note_id[:\s]+([0-9a-f]{16,})/i);
  if (!m)
    throw new Error(`没有从创建结果里取到笔记 id：${created.slice(0, 100)}`);
  return m[1];
}

const bullets = (text: string, box = false) =>
  text
    .split("\n")
    .map((l) => l.replace(/^[\s\-*•\d.、)]+/, "").trim())
    .filter(Boolean)
    .map((l) => (box ? `- [ ] ${l}` : `- ${l}`))
    .join("\n");

// ── 任务笔记 ──

export interface TaskNoteInput {
  taskTitle: string;
  taskLink?: string;
  deliverable: string;
  purpose: string;
  steps: string;
  project?: string;
}

export function buildTaskNoteBody(i: TaskNoteInput): string {
  return [
    `## 任务\n${i.taskLink ? `[${i.taskTitle}](${i.taskLink})` : i.taskTitle}`,
    `## 交付成果\n${i.deliverable}`,
    `## 行动目的\n${i.purpose.trim() || "（为什么要做这件事？）"}`,
    `## 行动步骤\n${bullets(i.steps, true) || "- [ ] （第一步做什么？）"}`,
    "## 进展记录\n",
    "## 复盘\n",
  ].join("\n\n");
}

export async function createTaskNote(
  taskKey: string,
  i: TaskNoteInput,
): Promise<TaskNoteRef> {
  const created = await createNote({
    title: truncate(i.deliverable.trim(), 30),
    body: buildTaskNoteBody(i),
    tags: ["任务笔记", ...(i.project ? [i.project] : [])],
    source: "tinycast-ideashell",
  });
  const ref: TaskNoteRef = {
    noteId: noteIdOf(created),
    deliverable: i.deliverable.trim(),
    project: i.project,
    createdAt: Date.now(),
  };
  await saveTaskNote(taskKey, ref);
  return ref;
}

/**
 * 把笔记正文整理成适合在右侧详情里显示的 Markdown：
 * 末尾的「#标签 #标签」行会被渲染成一级标题，所以改成「标签：a b」；其余行里单独成行的标签同理。
 */
export function displayNote(text: string): string {
  const lines = text.split("\n").map((l) => {
    const t = l.trim();
    if (/^(?:#[^\s#]+\s*)+$/.test(t))
      return `标签：${t.replace(/#/g, "").trim().split(/\s+/).join("　")}`;
    return l;
  });
  return lines.join("\n").trim();
}

// ── 按小节读写笔记正文 ──

const HEADING = /^##\s+(.*)$/;
const TAG_LINE = /^(?:#[^\s#]+\s*)+$/;

/** 修改 `## 标题` 小节：fn 收到现有正文，返回新正文；小节不存在则追加到末尾（标签行之前） */
export function editSection(
  content: string,
  title: string,
  fn: (existing: string) => string,
): string {
  const lines = content.split("\n");
  const start = lines.findIndex((l) => HEADING.exec(l)?.[1].trim() === title);
  if (start < 0) {
    let end = lines.length;
    while (
      end > 0 &&
      (lines[end - 1].trim() === "" || TAG_LINE.test(lines[end - 1].trim()))
    )
      end--;
    const tail = lines.slice(end);
    return [
      ...lines.slice(0, end),
      "",
      `## ${title}`,
      fn("").trim(),
      ...tail,
    ].join("\n");
  }
  let end = lines.findIndex((l, i) => i > start && HEADING.test(l));
  if (end < 0) {
    end = lines.length;
    while (
      end > start + 1 &&
      (lines[end - 1].trim() === "" || TAG_LINE.test(lines[end - 1].trim()))
    )
      end--;
  }
  const body = lines
    .slice(start + 1, end)
    .join("\n")
    .trim();
  const next = fn(body).trim();
  return [...lines.slice(0, start + 1), next, "", ...lines.slice(end)].join(
    "\n",
  );
}

async function editNote(
  noteId: string,
  title: string,
  fn: (existing: string) => string,
): Promise<void> {
  const detail = await getNoteDetail(noteId);
  const content = detail.content ?? detail.body ?? "";
  await updateNote({ noteId, body: editSection(content, title, fn) });
}

/** 在「进展记录」里追加一条（带日期） */
export function appendProgress(noteId: string, text: string): Promise<void> {
  return editNote(
    noteId,
    "进展记录",
    (old) =>
      `${old}${old ? "\n" : ""}- ${formatMinute(new Date())} ${text.trim()}`,
  );
}

/** 写入「复盘」 */
export function appendReview(noteId: string, text: string): Promise<void> {
  return editNote(
    noteId,
    "复盘",
    (old) =>
      `${old}${old ? "\n\n" : ""}${formatMinute(new Date())}：${text.trim()}`,
  );
}

/** 把任务链接写进任务笔记「任务」小节（任务在滴答里换了链接时用） */
export function setTaskLink(
  noteId: string,
  title: string,
  link: string,
): Promise<void> {
  return editNote(noteId, "任务", () => `[${title}](${link})`);
}

// ── 项目主页笔记 ──

export function buildProjectHomeBody(
  keyword: string,
  tags: string[],
  links: string,
): string {
  return [
    `## 目标\n（这个项目最终要达成什么？）`,
    `## 交付成果\n（要交付的成果，而不是要做的事情。例如「完成一篇可发表的论文初稿」）`,
    `## 任务笔记（自动汇总）\n${links || "（还没有任务笔记）"}`,
    `## 项目状态（自动汇总）\n（在项目主页按 ⌘R 更新：下一步、成果进度、近 7 天专注）`,
    `## 资料与链接\n- （把资料、链接贴在这里）`,
    `## 里程碑与进展\n- ${formatMinute(new Date())} 建立项目主页`,
    `## 复盘与经验\n`,
    `项目关键词：${[keyword, ...tags].join("、")}`,
  ].join("\n\n");
}

export async function createProjectHome(
  keyword: string,
  tags: string[],
  links: string,
): Promise<string> {
  const created = await createNote({
    title: truncate(`${keyword} 项目主页`, 30),
    body: buildProjectHomeBody(keyword, tags, links),
    tags: ["项目主页", keyword],
    source: "tinycast-ideashell",
  });
  const id = noteIdOf(created);
  await saveProjectHome(keyword, id);
  return id;
}

/** 刷新项目主页里「任务笔记（自动汇总）」小节 */
export function refreshProjectHomeLinks(
  noteId: string,
  links: string,
): Promise<void> {
  return editNote(
    noteId,
    "任务笔记（自动汇总）",
    () => links || "（还没有任务笔记）",
  );
}

/** 一次读写，同时更新多个小节 */
export async function editSections(
  noteId: string,
  edits: Array<[string, string]>,
): Promise<void> {
  const detail = await getNoteDetail(noteId);
  let content = detail.content ?? detail.body ?? "";
  for (const [title, text] of edits)
    content = editSection(content, title, () => text);
  await updateNote({ noteId, body: content });
}

/** 统计「行动步骤」小节里的 `- [x]` / `- [ ]`；没有步骤返回 null */
export function stepProgress(
  content: string,
): { done: number; total: number } | null {
  const lines = content.split("\n");
  const start = lines.findIndex(
    (l) => HEADING.exec(l)?.[1].trim() === "行动步骤",
  );
  if (start < 0) return null;
  let done = 0;
  let total = 0;
  for (let i = start + 1; i < lines.length && !HEADING.test(lines[i]); i++) {
    const m = lines[i].match(/^\s*[-*]\s+\[([ xX])\]\s+(.*)$/);
    // 模板里的占位步骤「（第一步做什么？）」不算
    if (!m || m[2].trim().startsWith("（")) continue;
    total++;
    if (m[1] !== " ") done++;
  }
  return total > 0 ? { done, total } : null;
}

/** 里程碑文字：有任务笔记就写交付成果并带链接，否则写任务标题 */
export function milestoneText(title: string, ref?: TaskNoteRef): string {
  return ref
    ? `完成：${ref.deliverable}（[任务笔记](${noteUrl(ref.noteId)})）`
    : `完成：${title}`;
}

/** 在项目主页「里程碑与进展」追加一行；没有项目主页就什么都不做 */
export async function recordMilestone(
  keyword: string,
  text: string,
): Promise<void> {
  const homeId = (await loadProjectHomes())[keyword];
  if (!homeId) return;
  await editNote(
    homeId,
    "里程碑与进展",
    (old) => `${old}${old ? "\n" : ""}- ${formatMinute(new Date())} ${text}`,
  );
}

export function taskNoteLinks(
  refs: Array<TaskNoteRef & { taskKey?: string }>,
): string {
  return refs
    .map((r) => `- [${r.deliverable}](${noteUrl(r.noteId)})`)
    .join("\n");
}
