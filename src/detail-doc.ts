/**
 * 详情区文档：右侧预览由「Markdown 正文 + 元信息行」两部分组成。
 * 统计数字放在元信息行里（原生对齐、整洁），叙述性内容（待办 / 时间轴 / 观察）放在 Markdown 里；
 * `copy` 是合并后的完整 Markdown，用于复制。
 */
export interface DocRow {
  title: string;
  text: string;
}

/** null 表示一条分隔线，用于把元信息分组 */
export type DocItem = DocRow | null;

export interface DetailDoc {
  markdown: string;
  rows: DocItem[];
  tagsTitle: string;
  tags: string[];
  copy: string;
}

export function makeDoc(p: {
  title: string;
  subtitle?: string;
  rows?: DocItem[];
  tagsTitle?: string;
  tags?: string[];
  /** 叙述性 Markdown（以 ## 小节组织） */
  sections?: string[];
  /** 只在「复制」时附带的小节（例如明细），不在预览里重复显示 */
  copyOnly?: string[];
}): DetailDoc {
  const rows = p.rows ?? [];
  const tags = p.tags ?? [];
  const tagsTitle = p.tagsTitle ?? "标签";
  const sections = (p.sections ?? []).filter(Boolean);
  const copyOnly = (p.copyOnly ?? []).filter(Boolean);

  const head = [`# ${p.title}`, ...(p.subtitle ? ["", p.subtitle] : [])].join("\n");
  const markdown = [head, ...sections].join("\n\n");

  const stats: string[] = [];
  const flat = rows.filter((r): r is DocRow => r !== null);
  if (flat.length > 0) stats.push(["## 概况", "", ...flat.map((r) => `- ${r.title}：${r.text}`)].join("\n"));
  if (tags.length > 0) stats.push(`${tagsTitle}：${tags.join("　")}`);
  const copy = [head, ...stats, ...sections, ...copyOnly].join("\n\n");

  return { markdown, rows, tagsTitle, tags, copy };
}
