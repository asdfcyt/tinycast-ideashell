import { getNoteId, listSpeakers, listTodos, NoteInfo, searchBySpeaker, searchNotes, Speaker, TodoItem } from "./api";
import { DetailDoc, DocItem, makeDoc } from "./detail-doc";
import { extractTags, memoText } from "./note-text";
import { localDay } from "./timeline-data";
import { formatDate, truncate } from "./utils";

export interface DossierNote {
  note: NoteInfo;
  /** 正文 / 标题里出现关键词的次数（说话人命中的笔记可能为 0） */
  mentions: number;
  /** 直接提及（文字里出现关键词，或有该说话人发言） */
  direct: boolean;
  viaSpeaker: boolean;
  snippet: string;
  tags: string[];
  /** 本地日期 YYYY-MM-DD */
  day: string;
}

export interface DossierData {
  query: string;
  /** 时间倒序 */
  notes: DossierNote[];
  directCount: number;
  todos: TodoItem[];
  speakers: Speaker[];
  /** Markdown 简报 */
  doc: DetailDoc;
  /** 完整 Markdown（用于复制） */
  brief: string;
}

const norm = (s: string) => s.toLowerCase();

function countOf(hay: string, needle: string): number {
  if (!needle) return 0;
  return hay.split(needle).length - 1;
}

function makeSnippet(body: string, q: string, fallback: string): string {
  const i = norm(body).indexOf(norm(q));
  if (i < 0) return truncate(fallback.replace(/\s+/g, " ").trim(), 70);
  const from = Math.max(0, i - 28);
  const to = Math.min(body.length, i + q.length + 56);
  const s = body
    .slice(from, to)
    .replace(/\*\*|__/g, "")
    .replace(/\s+/g, " ")
    .trim();
  return `${from > 0 ? "…" : ""}${s}${to < body.length ? "…" : ""}`;
}

function daysBetween(fromDay: string, toDay: string): number {
  const a = new Date(`${fromDay}T00:00:00`).getTime();
  const b = new Date(`${toDay}T00:00:00`).getTime();
  return Math.round((b - a) / 86400000);
}

function ago(days: number): string {
  if (days <= 0) return "今天";
  if (days === 1) return "昨天";
  if (days < 30) return `${days} 天前`;
  if (days < 365) return `约 ${Math.round(days / 30)} 个月前`;
  return `约 ${(days / 365).toFixed(1)} 年前`;
}

const BARS = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"];

/** 近 12 个月（含本月）每月直接提及的笔记数 */
function monthlySeries(days: string[], now: Date): { labels: string[]; counts: number[] } {
  const labels: string[] = [];
  for (let i = 11; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    labels.push(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`);
  }
  const counts = labels.map((l) => days.filter((d) => d.startsWith(l)).length);
  return { labels, counts };
}

function sparkline(counts: number[]): string {
  const max = Math.max(...counts, 0);
  return counts
    .map((c) => (c === 0 ? "·" : BARS[Math.min(BARS.length - 1, Math.ceil((c / max) * BARS.length) - 1)]))
    .join("");
}

function emptyData(query: string): DossierData {
  return {
    query,
    notes: [],
    directCount: 0,
    todos: [],
    speakers: [],
    doc: makeDoc({ title: "" }),
    brief: "",
  };
}

/**
 * 人物 / 主题档案：围绕一个名字或关键词，聚合
 * 提及过的笔记（多路语义检索 + 字面校验）、相关待办、该说话人的录音笔记，
 * 并统计首次 / 最近提及、近 12 个月频率、高频同现标签，生成可复制的 Markdown 简报。
 */
export async function loadDossier(query: string, now = new Date()): Promise<DossierData> {
  const q = query.trim();
  if (!q) return emptyData("");

  // 多种问法各检索一次再合并，扩大覆盖面（接口单次最多返回 20 条）
  const variants = [...new Set([q, `关于${q}`, `${q} 计划 待办`, `${q} 沟通 讨论`])];
  const [searches, openTodos, doneTodos, allSpeakers] = await Promise.all([
    Promise.all(variants.map((v) => searchNotes(v, 20).catch(() => [] as NoteInfo[]))),
    listTodos({ keyword: q, isCompleted: false, limit: 50 }).catch(() => [] as TodoItem[]),
    listTodos({ keyword: q, isCompleted: true, limit: 50 }).catch(() => [] as TodoItem[]),
    listSpeakers().catch(() => [] as Speaker[]),
  ]);

  const lq = norm(q);
  const speakers = allSpeakers.filter((s) => {
    const n = norm(s.name);
    return n.length >= 1 && (n.includes(lq) || (n.length >= 2 && lq.includes(n)));
  });
  const speakerNotes =
    speakers.length > 0
      ? await searchBySpeaker(
          speakers.map((s) => s.id),
          20,
        ).catch(() => [])
      : [];
  const speakerIds = new Set(speakerNotes.map(getNoteId));

  // 合并去重
  const byId = new Map<string, NoteInfo>();
  for (const n of [...searches.flat(), ...speakerNotes]) {
    const id = getNoteId(n);
    if (!id) continue;
    const old = byId.get(id);
    if (!old || (!old.text && n.text)) byId.set(id, n);
  }

  const notes: DossierNote[] = [...byId.values()].map((note) => {
    const body = memoText(note.text ?? "");
    const mentions = countOf(norm(`${note.title}\n${body}`), lq);
    const viaSpeaker = speakerIds.has(getNoteId(note));
    return {
      note,
      mentions,
      viaSpeaker,
      direct: mentions > 0 || viaSpeaker,
      snippet: makeSnippet(body, q, note.summary ?? note.title),
      tags: extractTags(note, body),
      day: localDay(note.created_at),
    };
  });
  notes.sort((a, b) => (b.note.created_at ?? "").localeCompare(a.note.created_at ?? ""));

  const direct = notes.filter((n) => n.direct);
  const todos = [...openTodos, ...doneTodos].sort(
    (a, b) => Number(a.is_completed) - Number(b.is_completed) || (b.date ?? "").localeCompare(a.date ?? ""),
  );

  const doc = buildBrief({ q, notes, direct, todos, speakers, now });
  return {
    query: q,
    notes,
    directCount: direct.length,
    todos,
    speakers,
    doc,
    brief: doc.copy,
  };
}

function buildBrief(p: {
  q: string;
  notes: DossierNote[];
  direct: DossierNote[];
  todos: TodoItem[];
  speakers: Speaker[];
  now: Date;
}): DetailDoc {
  const { q, notes, direct, todos, speakers, now } = p;
  const today = formatDate(now);
  const related = notes.length - direct.length;
  const openCount = todos.filter((t) => !t.is_completed).length;
  const doneCount = todos.length - openCount;
  const voiceCount = direct.filter((n) => n.viaSpeaker).length;

  const title = `「${q}」档案`;
  const subtitle = `直接提及 ${direct.length} 条笔记，另有 ${related} 条语义相关`;

  if (direct.length === 0 && todos.length === 0) {
    return makeDoc({
      title,
      subtitle,
      sections: [
        "没有找到直接提及的记录。下方「可能相关」是语义相近的笔记，换个叫法（全名 / 昵称 / 项目代号）再试试。",
      ],
    });
  }

  const rows: DocItem[] = [];
  const sections: string[] = [];

  const dated = direct.filter((n) => n.day);
  if (dated.length > 0) {
    const newest = dated[0];
    const oldest = dated[dated.length - 1];
    const distinctDays = new Set(dated.map((n) => n.day)).size;
    const total = direct.reduce((s, n) => s + n.mentions, 0);
    rows.push(
      {
        title: "首次提及",
        text: `${oldest.day}，${ago(daysBetween(oldest.day, today))}（${truncate(oldest.note.title, 16)}）`,
      },
      {
        title: "最近提及",
        text: `${newest.day}，${ago(daysBetween(newest.day, today))}（${truncate(newest.note.title, 16)}）`,
      },
      { title: "累计提及", text: `${total} 次，分布在 ${distinctDays} 个日期` },
    );

    const { labels, counts } = monthlySeries(
      dated.map((n) => n.day),
      now,
    );
    if (counts.some((c) => c > 0)) {
      rows.push({
        title: `近 12 个月`,
        text: `${sparkline(counts)}　${labels[0].slice(2)} 至 ${labels[labels.length - 1].slice(2)}`,
      });
      const detail = counts
        .map((c, i) => (c > 0 ? `${labels[i].slice(2)}  ${c}` : ""))
        .filter(Boolean)
        .join("　　");
      if (detail) rows.push({ title: "月度笔记数", text: detail });
    }
  }
  if (rows.length > 0) rows.push(null);
  rows.push({ title: "待办", text: `${openCount} 未完成，${doneCount} 已完成` });
  if (speakers.length > 0) {
    rows.push({ title: "说话人", text: `${speakers.map((s) => s.name).join("、")}，有其发言的笔记 ${voiceCount} 条` });
  }

  const tagCount = new Map<string, number>();
  for (const n of direct) for (const t of n.tags) tagCount.set(t, (tagCount.get(t) ?? 0) + 1);
  tagCount.delete(q);
  const topTags = [...tagCount.entries()].sort((a, b) => b[1] - a[1]).slice(0, 8);

  const recent = direct.filter((n) => n.snippet).slice(0, 4);
  if (recent.length > 0) {
    sections.push(
      [
        "## 最近的提及",
        "",
        ...recent.flatMap((n) => [`> ${n.snippet}`, `> — ${truncate(n.note.title, 24)}　${n.day}`, ""]),
      ]
        .join("\n")
        .trimEnd(),
    );
  }

  if (todos.length > 0) {
    const lines = todos.slice(0, 12).map((t) => {
      const when = [t.date, t.time].filter(Boolean).join(" ");
      return `- [${t.is_completed ? "x" : " "}] ${t.content}${when ? `（${when}）` : ""}`;
    });
    if (todos.length > 12) lines.push(`- 另有 ${todos.length - 12} 条`);
    sections.push(["## 相关待办", "", ...lines].join("\n"));
  }

  const gap = dated.length > 0 ? daysBetween(dated[0].day, today) : 0;
  if (gap >= 30) sections.push(`> 距上次提及已 ${gap} 天，见面 / 推进前也许值得先补一条近况。`);

  sections.push(`*基于对「${q}」的多路语义检索（每路最多 20 条）并做字面校验，可能不是全部记录。*`);

  return makeDoc({
    title,
    subtitle,
    rows,
    tagsTitle: "常伴随的标签",
    tags: topTags.map(([t, c]) => `#${t}  ${c}`),
    sections,
  });
}
