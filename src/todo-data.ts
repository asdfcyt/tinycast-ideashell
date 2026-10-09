import { listTodos, TodoItem } from "./api";
import { loadMap } from "./dida";
import { emptyFocus, fetchFocusSummary, FocusSummary } from "./dida-focus";
import { DidaTask, fetchDidaOverview, projectLabel } from "./dida-tasks";
import { isDidaConnected } from "./dida";
import { cleanTitle, isMarkedImportant, isMarkedUrgent, Quadrant, quadrantOf as quadrantOfTodo } from "./todo-meta";
import { formatDate } from "./utils";

/** 列表里的一行待办：来自滴答清单（主）或闪念贝壳（辅，尚未同步到滴答的） */
export interface TodoRow {
  /** `dida:<id>` | `idea:<id>` */
  key: string;
  source: "dida" | "idea";
  id: string;
  /** 滴答任务所在清单 id */
  projectId: string;
  /** 滴答清单名（收集箱 / 自建清单） */
  listName: string;
  title: string;
  /** 闪念贝壳待办的原始文字（含 !重要 / !紧急 标记） */
  rawTitle: string;
  content: string;
  date: string | null;
  time: string | null;
  /** 0 无 / 1 低 / 3 中 / 5 高 */
  priority: number;
  urgentMark: boolean;
  tags: string[];
  done: boolean;
  /** 滴答任务对应的闪念贝壳待办 id（经同步产生） */
  ideaId?: string;
}

export interface TodoData {
  open: TodoRow[];
  done: TodoRow[];
  connected: boolean;
  warning?: string;
  /** 闪念贝壳原始待办，供「同步到滴答」使用 */
  ideaOpen: TodoItem[];
  ideaDone: TodoItem[];
  /** 近 7 天的专注记录（滴答番茄钟 / 正计时） */
  focus: FocusSummary;
}

export function ideaRow(t: TodoItem): TodoRow {
  return {
    key: `idea:${t.id}`,
    source: "idea",
    id: t.id,
    projectId: "",
    listName: "",
    title: cleanTitle(t.content),
    rawTitle: t.content,
    content: "",
    date: t.date,
    time: t.time,
    priority: isMarkedImportant(t.content) ? 5 : 0,
    urgentMark: isMarkedUrgent(t.content),
    tags: [],
    done: t.is_completed,
  };
}

export function didaRow(t: DidaTask, names: Record<string, string>, ideaId?: string): TodoRow {
  return {
    key: `dida:${t.id}`,
    source: "dida",
    id: t.id,
    projectId: t.projectId,
    listName: projectLabel(names, t.projectId),
    title: t.title,
    rawTitle: t.title,
    content: t.content,
    date: t.date,
    time: t.time,
    priority: t.priority,
    urgentMark: false,
    tags: t.tags,
    done: t.done,
    ideaId,
  };
}

export const isImportant = (r: TodoRow) => r.priority >= 3;

export function quadrantOfRow(r: TodoRow, now = new Date()): Quadrant {
  const base = quadrantOfTodo({ content: r.urgentMark ? `${r.title} !紧急` : r.title, date: r.date }, now);
  const urgent = base === "q1" || base === "q3";
  if (isImportant(r)) return urgent ? "q1" : "q2";
  return urgent ? "q3" : "q4";
}

export const byDateTime = (a: TodoRow, b: TodoRow) =>
  `${a.date ?? ""} ${a.time ?? ""}`.localeCompare(`${b.date ?? ""} ${b.time ?? ""}`);

/** 同时拉取滴答（主）和闪念贝壳（辅），合并去重 */
export async function loadTodoData(): Promise<TodoData> {
  const [ideaOpen, ideaDone, connected] = await Promise.all([
    listTodos({ isCompleted: false, limit: 200 }),
    listTodos({ isCompleted: true, limit: 20 }),
    isDidaConnected(),
  ]);

  if (!connected) {
    return {
      open: ideaOpen.map(ideaRow),
      done: ideaDone.map(ideaRow),
      connected,
      ideaOpen,
      ideaDone,
      focus: emptyFocus(),
    };
  }

  let warning: string | undefined;
  let overview: Awaited<ReturnType<typeof fetchDidaOverview>> | null = null;
  const focusP = fetchFocusSummary().catch(() => emptyFocus());
  try {
    overview = await fetchDidaOverview();
    warning = overview.warning;
  } catch (e) {
    warning = `滴答清单读取失败：${e instanceof Error ? e.message : String(e)}`;
  }

  const map = await loadMap();
  const ideaByTask = new Map(Object.entries(map).map(([ideaId, m]) => [m.taskId, ideaId]));
  const names = overview?.projects ?? {};
  const didaOpen = overview ? [...overview.overdue, ...overview.upcoming, ...overview.undated] : [];
  const seen = new Set([...didaOpen, ...(overview?.done ?? [])].map((t) => t.id));
  // 已同步到滴答、且这次拉到了对应滴答任务的，就只显示滴答那条
  const visible = (t: TodoItem) => !(map[t.id] && seen.has(map[t.id].taskId));

  const open = [
    ...didaOpen.map((t) => didaRow(t, names, ideaByTask.get(t.id))),
    ...ideaOpen.filter(visible).map(ideaRow),
  ];
  const done = [
    ...(overview?.done ?? []).map((t) => didaRow(t, names, ideaByTask.get(t.id))),
    ...ideaDone.filter(visible).map(ideaRow),
  ];
  done.sort((a, b) => `${b.date ?? ""}${b.time ?? ""}`.localeCompare(`${a.date ?? ""}${a.time ?? ""}`));
  return { open, done: done.slice(0, 5), connected, warning, ideaOpen, ideaDone, focus: await focusP };
}

export const todayString = () => formatDate(new Date());
