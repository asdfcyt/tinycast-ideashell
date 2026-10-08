import {
  Action,
  ActionPanel,
  Clipboard,
  Color,
  Icon,
  List,
  popToRoot,
  showHUD,
  showToast,
  Toast,
} from "@raycast/api";
import { useEffect, useMemo, useState } from "react";
import { createNote, createTodos, FolderInfo, listFolders } from "./api";
import { analyzeCapture, CaptureKind, matchFolder } from "./capture-parse";
import { appendToToday, nowMinuteStamp } from "./daily";
import { getDefaultTags, truncate } from "./utils";

interface Plan {
  kind: CaptureKind;
  title: string;
  subtitle: string;
  icon: { source: Icon; tintColor: Color };
  actionTitle: string;
  run: () => Promise<string>; // 返回成功提示
}

const firstLine = (s: string) => s.split(/\r?\n/).find((l) => l.trim())?.trim() ?? "";

async function execute(label: string, run: () => Promise<string>) {
  const toast = await showToast({ style: Toast.Style.Animated, title: `正在${label}...` });
  try {
    const message = await run();
    toast.hide();
    await showHUD(message);
    await popToRoot({ clearSearchBar: true });
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = `${label}失败`;
    toast.message = error instanceof Error ? error.message : String(error);
  }
}

export default function Command() {
  const [text, setText] = useState("");
  const [folders, setFolders] = useState<FolderInfo[]>([]);
  const [clip, setClip] = useState("");

  useEffect(() => {
    listFolders()
      .then(setFolders)
      .catch(() => {});
    Clipboard.readText()
      .then((t) => setClip((t ?? "").trim()))
      .catch(() => {});
  }, []);

  const plans = useMemo<Plan[]>(() => {
    const input = text.trim();
    if (!input) return [];
    const a = analyzeCapture(input);
    if (!a.body) return [];

    const folder = matchFolder(a.folderName, folders);
    const noteTags = [...new Set([...getDefaultTags(), ...a.tags])];
    const when = [a.todo.date, a.todo.time].filter(Boolean).join(" ");
    const noteMeta = [
      ...a.tags.map((t) => `#${t}`),
      a.folderName ? (folder ? `📁 ${folder.name}` : `⚠️ 文件夹「${a.folderName}」不存在，将不放入文件夹`) : "",
    ].filter(Boolean);

    const todoPlan: Plan = {
      kind: "todo",
      title: a.todo.content,
      subtitle: `待办 · ${when || "无日期"}`,
      icon: { source: Icon.CheckCircle, tintColor: Color.Green },
      actionTitle: "创建待办",
      run: async () => {
        const { content, date, time } = a.todo;
        await createTodos([{ content, ...(date ? { date } : {}), ...(time ? { time } : {}) }]);
        return `✅ 已添加待办：${content}${when ? `（${when}）` : ""}`;
      },
    };

    const dailyPlan: Plan = {
      kind: "daily",
      title: truncate(firstLine(input), 60),
      subtitle: `追加到今天的 Daily Note · - **${nowMinuteStamp()}** …`,
      icon: { source: Icon.Calendar, tintColor: Color.Blue },
      actionTitle: "追加到 Daily Note",
      run: async () => {
        await appendToToday(input);
        return `✅ 已追加到 Daily Note：${truncate(firstLine(input), 20)}`;
      },
    };

    const noteTitle = truncate(firstLine(a.body), 30);
    const notePlan: Plan = {
      kind: "note",
      title: noteTitle,
      subtitle: ["笔记", ...noteMeta].join(" · "),
      icon: { source: Icon.Document, tintColor: Color.Orange },
      actionTitle: "保存为笔记",
      run: async () => {
        await createNote({
          title: noteTitle,
          body: a.body,
          tags: noteTags.length > 0 ? noteTags : undefined,
          folder: folder?.id,
          source: "tinycast",
        });
        return `✅ 已保存笔记：${truncate(noteTitle, 20)}`;
      },
    };

    const all: Record<CaptureKind, Plan> = { todo: todoPlan, daily: dailyPlan, note: notePlan };
    const order: CaptureKind[] = [a.recommended, ...(["daily", "note", "todo"] as CaptureKind[]).filter((k) => k !== a.recommended)];
    return order.map((k) => all[k]);
  }, [text, folders]);

  const clipPlans: Plan[] = useMemo(() => {
    if (!clip) return [];
    const title = truncate(firstLine(clip), 30);
    return [
      {
        kind: "note",
        title: "把剪贴板存为笔记",
        subtitle: truncate(firstLine(clip), 60),
        icon: { source: Icon.Clipboard, tintColor: Color.Orange },
        actionTitle: "保存剪贴板为笔记",
        run: async () => {
          const tags = getDefaultTags();
          await createNote({ title, body: clip, tags: tags.length ? tags : undefined, source: "tinycast" });
          return `✅ 已保存剪贴板：${truncate(title, 20)}`;
        },
      },
      {
        kind: "daily",
        title: "把剪贴板追加到 Daily Note",
        subtitle: truncate(firstLine(clip), 60),
        icon: { source: Icon.Clipboard, tintColor: Color.Blue },
        actionTitle: "追加剪贴板到 Daily Note",
        run: async () => {
          await appendToToday(clip);
          return `✅ 已追加到 Daily Note：${truncate(title, 20)}`;
        },
      },
    ];
  }, [clip]);

  const renderPlan = (plan: Plan, recommended: boolean) => (
    <List.Item
      key={`${plan.kind}-${plan.title}`}
      title={plan.title}
      subtitle={plan.subtitle}
      icon={plan.icon}
      accessories={recommended ? [{ tag: { value: "推荐", color: Color.Green } }] : []}
      actions={
        <ActionPanel>
          <Action title={plan.actionTitle} icon={Icon.ArrowRight} onAction={() => execute(plan.actionTitle, plan.run)} />
        </ActionPanel>
      }
    />
  );

  return (
    <List
      filtering={false}
      onSearchTextChange={setText}
      searchBarPlaceholder="随手输入：明天15:00开会 → 待办；今天试了新工作流 → 日记；#读书 @阅读笔记 …… → 笔记"
    >
      {plans.length > 0 && <List.Section title="将会执行">{plans.map((p, i) => renderPlan(p, i === 0))}</List.Section>}

      {plans.length === 0 && clipPlans.length > 0 && (
        <List.Section title="剪贴板">{clipPlans.map((p) => renderPlan(p, false))}</List.Section>
      )}

      {plans.length === 0 && (
        <List.EmptyView
          icon={Icon.Bolt}
          title="一个输入框，自动分流"
          description={
            "明天 15:00 开会 → 待办\n今天试了新的工作流 → 追加到 Daily Note\n#读书 @阅读笔记 《穷查理宝典》很有启发 → 带标签、进文件夹的笔记\n待办：续费域名 → 强制作为待办"
          }
        />
      )}
    </List>
  );
}
