import { LocalStorage } from "@raycast/api";
import { getPrefs } from "./api";
import { formatDate, truncate } from "./utils";

export interface TemplateField {
  name: string;
  /** 多行输入框；否则为单行 */
  multiline: boolean;
}

export interface Template {
  name: string;
  fields: TemplateField[];
  tags: string[];
  folderName?: string;
  /** builtin 内置 / pref 偏好设置里的自定义 / local 在命令里新建的 */
  source: "builtin" | "pref" | "local";
}

const f = (name: string, multiline = false): TemplateField => ({ name, multiline });

/** 内置模板：想改 / 想加，在偏好设置的「Templates」里写同名或新名字即可 */
export const BUILTIN_TEMPLATES: Template[] = [
  {
    name: "练习",
    fields: [f("内容", true), f("自评", true), f("问题", true), f("下次", true)],
    tags: ["练习"],
    source: "builtin",
  },
  {
    name: "阅读",
    fields: [f("书名 / 来源"), f("摘录", true), f("想法", true)],
    tags: ["阅读", "书摘"],
    source: "builtin",
  },
  {
    name: "决策",
    fields: [f("决策", true), f("原因", true), f("备选", true), f("预期结果", true), f("复盘日期")],
    tags: ["决策"],
    source: "builtin",
  },
  {
    name: "复盘",
    fields: [f("发生了什么", true), f("学到了什么", true), f("下次怎么做", true)],
    tags: ["复盘"],
    source: "builtin",
  },
  {
    name: "指标",
    fields: [f("指标"), f("数值"), f("备注")],
    tags: ["指标"],
    source: "builtin",
  },
];

/**
 * 解析偏好设置里的自定义模板。语法（多个模板用 ; 或换行分隔）：
 *
 *   名称:字段1,字段2+,字段3 #标签1 #标签2 @文件夹
 *
 * 字段名后面加 + 表示多行输入框，否则是单行。例：
 *   刻印:作品,印文,感受+,问题+ #篆刻 #练习 @篆刻练习; 体重:体重,备注 #体重
 */
export function parseTemplates(source: string, from: Template["source"] = "pref"): Template[] {
  const result: Template[] = [];
  for (const chunk of source.split(/[;；\n]/)) {
    const m = chunk.trim().match(/^([^:：]+)[:：](.*)$/);
    if (!m) continue;
    const name = m[1].trim();

    const tags: string[] = [];
    let folderName: string | undefined;
    const fieldPart = m[2]
      .replace(/(^|\s)#([^\s#@]+)/g, (_x, sp: string, t: string) => {
        tags.push(t);
        return sp;
      })
      .replace(/(^|\s)@([^\s#@]+)/g, (_x, sp: string, fo: string) => {
        folderName ??= fo;
        return sp;
      });

    const fields = fieldPart
      .split(/[,，、]/)
      .map((s) => s.trim())
      .filter(Boolean)
      .map((s) => (s.endsWith("+") ? f(s.slice(0, -1).trim(), true) : f(s)))
      .filter((x) => x.name);

    if (name && fields.length > 0) {
      result.push({ name, fields, tags: [...new Set(tags)], folderName, source: from });
    }
  }
  return result;
}

const LOCAL_KEY = "user-templates-v1";

/** 在命令里新建的模板（存在本机，不用改偏好设置） */
export async function loadLocalTemplates(): Promise<Template[]> {
  try {
    const raw = await LocalStorage.getItem<string>(LOCAL_KEY);
    const list = raw ? (JSON.parse(raw) as Template[]) : [];
    return list.filter((t) => t?.name && Array.isArray(t.fields)).map((t) => ({ ...t, source: "local" as const }));
  } catch {
    return [];
  }
}

async function writeLocalTemplates(list: Template[]): Promise<void> {
  await LocalStorage.setItem(LOCAL_KEY, JSON.stringify(list));
}

/** 保存一个本地模板；replaceName 为被编辑的原名（改名时替换旧的），同名的本地模板也会被覆盖 */
export async function saveLocalTemplate(t: Template, replaceName?: string): Promise<void> {
  const keys = new Set([t.name.toLowerCase(), (replaceName ?? "").toLowerCase()]);
  const rest = (await loadLocalTemplates()).filter((x) => !keys.has(x.name.toLowerCase()));
  await writeLocalTemplates([...rest, { ...t, source: "local" }]);
}

export async function deleteLocalTemplate(name: string): Promise<void> {
  const rest = (await loadLocalTemplates()).filter((x) => x.name.toLowerCase() !== name.toLowerCase());
  await writeLocalTemplates(rest);
}

/** 模板 → 编辑框里的文本：每行一个字段，多行字段末尾加 + */
export function fieldsToText(t: Template): string {
  return t.fields.map((x) => (x.multiline ? `${x.name}+` : x.name)).join("\n");
}

/** 编辑框文本（每行一个字段，也接受逗号分隔）→ 模板；字段为空返回 null */
export function buildTemplate(opts: {
  name: string;
  fieldsText: string;
  tags: string;
  folderName?: string;
}): Template | null {
  const name = opts.name.trim().replace(/[:：;；]/g, "");
  const fields = opts.fieldsText
    .split(/[\n,，、]/)
    .map((x) => x.trim())
    .filter(Boolean)
    .map((x) => (x.endsWith("+") ? f(x.slice(0, -1).trim(), true) : f(x)))
    .filter((x) => x.name);
  if (!name || fields.length === 0) return null;
  const tags = [
    ...new Set(
      opts.tags
        .split(/[\s,，、]+/)
        .map((x) => x.replace(/^#+/, ""))
        .filter(Boolean),
    ),
  ];
  const folderName = opts.folderName?.trim().replace(/^@+/, "") || undefined;
  return { name, fields, tags, folderName, source: "local" };
}

/** 本地模板 > 偏好设置里的自定义模板 > 内置模板（同名时前者覆盖后者） */
export async function loadTemplates(): Promise<Template[]> {
  const raw = (getPrefs() as { templates?: string }).templates ?? "";
  const merged: Template[] = [];
  const seen = new Set<string>();
  for (const t of [...(await loadLocalTemplates()), ...parseTemplates(raw), ...BUILTIN_TEMPLATES]) {
    const key = t.name.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    merged.push(t);
  }
  return merged;
}

/** 按名字找模板：完全相同 → 包含（忽略大小写） */
export function findTemplate(name: string, list: Template[]): Template | undefined {
  const n = name.trim().toLowerCase();
  if (!n) return undefined;
  return list.find((t) => t.name.toLowerCase() === n) ?? list.find((t) => t.name.toLowerCase().includes(n));
}

/**
 * 生成笔记：标题固定为「模板名 日期」，正文每个字段一段 `**字段**：值`（多行值换行后接在下面）。
 * 格式固定，之后按字段精确解析 / 汇编不会有任何歧义。
 */
export function buildTemplateNote(t: Template, values: Record<string, string>, now = new Date()) {
  const blocks: string[] = [];
  for (const field of t.fields) {
    const v = (values[field.name] ?? "").trim();
    if (!v) continue;
    blocks.push(v.includes("\n") ? `**${field.name}**：\n${v}` : `**${field.name}**：${v}`);
  }
  return {
    title: truncate(`${t.name} ${formatDate(now)}`, 30),
    body: blocks.join("\n\n"),
    filled: blocks.length,
  };
}
