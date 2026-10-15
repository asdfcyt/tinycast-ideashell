import { LocalStorage } from "@raycast/api";
import { getNoteDetail, getNoteId, NoteInfo, searchNotes } from "./api";
import { mergeProjectHomes, mergeTaskNotes, TaskNoteRef } from "./task-notes";
import { mergeLocalTemplates, Template } from "./templates";
import { mergeProjects, ProjectStatus, WatchItem } from "./watchlist";

/**
 * 只读导入「拾忆」手机 App 的备份（全平台同步的第一阶段）。
 *
 * 手机端把项目 / 任务笔记 / 项目主页 / 模板等写成 JSON，放在闪念贝壳里一篇标题为「拾忆备份（请勿删除）」的笔记里。
 * 这里把它读回来，**只补本机没有的**（项目、任务笔记对应关系、项目主页、自定义模板），本机已有的一律不动，
 * 也不会回写备份笔记；手机独有的重温库、专注记录等忽略。凭证不在备份里。
 */

const BACKUP_TITLE = "拾忆备份（请勿删除）";
const BACKUP_TAG = "拾忆备份";
const FORMAT = "shiyi-backup";
const SUPPORTED_VERSION = 1;

const isBackupNote = (n: NoteInfo) =>
  n.title.trim() === BACKUP_TITLE || (n.tags ?? []).some((t) => t.replace(/^#+/, "").trim() === BACKUP_TAG);

interface PhoneProject {
  keyword: string;
  addedAt?: number;
  staleDays?: number;
  /** 手机端写的是枚举名：ACTIVE / SHORT / LONG / PAUSED */
  status?: string;
  next?: string;
  tags?: string[];
}

interface PhoneTemplate {
  name: string;
  fields?: Array<{ name: string; multiline?: boolean }>;
  tags?: string[];
  folderName?: string | null;
  builtin?: boolean;
}

interface PhoneBackup {
  format: string;
  version: number;
  exportedAt?: number;
  workspace?: {
    projects?: PhoneProject[];
    taskNotes?: Record<string, TaskNoteRef>;
    homes?: Record<string, string>;
    templates?: PhoneTemplate[];
  };
}

export interface ImportResult {
  exportedAt?: number;
  projects: number;
  taskNotes: number;
  homes: number;
  templates: number;
}

/** 从闪念贝壳读出备份笔记里的 JSON；没找到 / 内容不对抛出可直接给用户看的错误 */
export async function fetchPhoneBackup(): Promise<PhoneBackup> {
  const list = await searchNotes(BACKUP_TITLE, 20);
  const note = list.find(isBackupNote);
  if (!note) throw new Error("闪念贝壳里没有找到「拾忆备份」，请先在手机上点「备份到闪念贝壳」");
  const detail = await getNoteDetail(getNoteId(note));
  const content = detail.content ?? "";
  const start = content.indexOf("```json");
  const end = content.lastIndexOf("```");
  if (start < 0 || end <= start) throw new Error("备份笔记的内容不完整，请在手机上重新备份一次");
  let data: PhoneBackup;
  try {
    data = JSON.parse(content.slice(start + "```json".length, end).trim()) as PhoneBackup;
  } catch {
    throw new Error("备份笔记无法解析，请在手机上重新备份一次");
  }
  if (data.format !== FORMAT) throw new Error("这不是拾忆的备份");
  if (Number(data.version) > SUPPORTED_VERSION) throw new Error(`备份来自更新版本的拾忆（v${data.version}），请先升级本扩展`);
  return data;
}

const STATUS_FROM_PHONE: Record<string, ProjectStatus> = {
  ACTIVE: "active",
  SHORT: "short",
  LONG: "long",
  PAUSED: "paused",
};

/** 把手机备份合并进本机（只补不覆盖） */
export async function importPhoneBackup(): Promise<ImportResult> {
  const backup = await fetchPhoneBackup();
  const ws = backup.workspace ?? {};

  const projects = await mergeProjects(
    (ws.projects ?? []).map(
      (p): Partial<WatchItem> & { keyword: string } => ({
        keyword: p.keyword,
        addedAt: p.addedAt,
        staleDays: p.staleDays,
        status: STATUS_FROM_PHONE[String(p.status ?? "").toUpperCase()] ?? "active",
        next: p.next,
        tags: p.tags,
      }),
    ),
  );
  const taskNotes = await mergeTaskNotes(ws.taskNotes ?? {});
  const homes = await mergeProjectHomes(ws.homes ?? {});
  const templates = await mergeLocalTemplates(
    (ws.templates ?? [])
      .filter((t) => !t.builtin)
      .map((t): Partial<Template> & { name: string } => ({
        name: t.name,
        fields: (t.fields ?? []).map((f) => ({ name: f.name, multiline: !!f.multiline })),
        tags: t.tags,
        folderName: t.folderName ?? undefined,
      })),
  );
  return { exportedAt: backup.exportedAt, projects, taskNotes, homes, templates };
}

export function importSummary(r: ImportResult): string {
  const parts = [
    r.projects && `项目 ${r.projects}`,
    r.taskNotes && `任务笔记 ${r.taskNotes}`,
    r.homes && `项目主页 ${r.homes}`,
    r.templates && `模板 ${r.templates}`,
  ].filter(Boolean);
  return parts.length ? `已导入：${parts.join("、")}` : "已是最新，没有需要导入的";
}

const AUTO_KEY = "phone-backup-auto-import-at";
/** 自动导入的间隔：不用每次打开都读一遍备份笔记 */
const AUTO_INTERVAL_MS = 6 * 3600 * 1000;

/**
 * 打开待办 / 笔记列表时在后台自动导入手机备份（每 6 小时最多一次，静默：没有备份、没配 API Key、网络失败都不打扰）。
 * 返回这次新导入的条目总数（没有执行或没有新内容返回 0）。
 */
export async function autoImportPhoneBackup(force = false): Promise<number> {
  try {
    const last = Number((await LocalStorage.getItem<string>(AUTO_KEY)) ?? 0);
    if (!force && Date.now() - last < AUTO_INTERVAL_MS) return 0;
    const r = await importPhoneBackup();
    await LocalStorage.setItem(AUTO_KEY, String(Date.now()));
    return r.projects + r.taskNotes + r.homes + r.templates;
  } catch {
    return 0;
  }
}
