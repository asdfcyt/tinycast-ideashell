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
  builtin: boolean;
}

const f = (name: string, multiline = false): TemplateField => ({ name, multiline });

/** 内置模板：想改 / 想加，在偏好设置的「Templates」里写同名或新名字即可 */
export const BUILTIN_TEMPLATES: Template[] = [
  {
    name: "练习",
    fields: [f("内容", true), f("自评", true), f("问题", true), f("下次", true)],
    tags: ["练习"],
    builtin: true,
  },
  {
    name: "阅读",
    fields: [f("书名 / 来源"), f("摘录", true), f("想法", true)],
    tags: ["阅读", "书摘"],
    builtin: true,
  },
  {
    name: "决策",
    fields: [f("决策", true), f("原因", true), f("备选", true), f("预期结果", true), f("复盘日期")],
    tags: ["决策"],
    builtin: true,
  },
  {
    name: "复盘",
    fields: [f("发生了什么", true), f("学到了什么", true), f("下次怎么做", true)],
    tags: ["复盘"],
    builtin: true,
  },
  {
    name: "指标",
    fields: [f("指标"), f("数值"), f("备注")],
    tags: ["指标"],
    builtin: true,
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
export function parseTemplates(source: string): Template[] {
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
      result.push({ name, fields, tags: [...new Set(tags)], folderName, builtin: false });
    }
  }
  return result;
}

/** 内置模板 + 自定义模板（同名时自定义覆盖内置） */
export function getTemplates(): Template[] {
  const raw = (getPrefs() as { templates?: string }).templates ?? "";
  const custom = parseTemplates(raw);
  const overridden = new Set(custom.map((t) => t.name.toLowerCase()));
  return [...custom, ...BUILTIN_TEMPLATES.filter((t) => !overridden.has(t.name.toLowerCase()))];
}

/** 按名字找模板：完全相同 → 包含（忽略大小写） */
export function findTemplate(name: string, list = getTemplates()): Template | undefined {
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
