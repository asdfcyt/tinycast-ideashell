import {
  Action,
  ActionPanel,
  closeMainWindow,
  Form,
  Icon,
  showHUD,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useState } from "react";
import { runCapture } from "./capture-run";
import { didaTaskUrl, patchDidaTask } from "./dida-tasks";
import {
  appendProgress,
  appendReview,
  createTaskNote,
  loadProjectHomes,
  loadTaskNotes,
  noteUrl,
  refreshProjectHomeLinks,
  taskNoteLinks,
  TaskNoteRef,
} from "./task-notes";
import { TodoRow } from "./todo-data";
import { completeRow } from "./todo-ops";
import { setProjectNext } from "./watchlist";

const errMsg = (e: unknown) => (e instanceof Error ? e.message : String(e));

/** 设置项目的「下一步」：项目主页里最醒目的一句话，由你手写 */
export function NextForm({
  keyword,
  current,
  onDone,
}: {
  keyword: string;
  current: string;
  onDone: (next: string) => void;
}) {
  const { pop } = useNavigation();

  async function handleSubmit(values: Form.Values) {
    const value = String(values.next ?? "").trim();
    await setProjectNext(keyword, value);
    await showToast({ style: Toast.Style.Success, title: `已更新「${keyword}」的下一步` });
    onDone(value);
    pop();
  }

  return (
    <Form
      navigationTitle={`下一步 · ${keyword}`}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="保存" icon={Icon.Check} onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="next"
        title="下一步"
        defaultValue={current}
        placeholder="下一步具体要做什么？留空表示清除"
        autoFocus
      />
      <Form.Description text="写成能直接开始的动作，例如「临《洛神赋》第三段，写 5 遍」。项目列表里会直接显示这一句。" />
    </Form>
  );
}

/** 项目下所有任务笔记的链接汇总，写回项目主页笔记（有的话） */
export async function syncProjectHome(project: string | undefined): Promise<void> {
  if (!project) return;
  const homes = await loadProjectHomes();
  const homeId = homes[project];
  if (!homeId) return;
  const refs = Object.values(await loadTaskNotes()).filter((r) => r.project === project);
  await refreshProjectHomeLinks(homeId, taskNoteLinks(refs));
}

/**
 * 创建任务笔记（防弹笔记法）：一个任务，一条笔记；
 * 笔记的单位是「要交付的成果」，不是「要做的事情」本身；步骤只是达成成果的路径。
 */
export function TaskNoteForm({
  row,
  project,
  onDone,
}: {
  row: TodoRow;
  project?: string;
  onDone: (ref: TaskNoteRef) => void;
}) {
  const { pop } = useNavigation();
  const [saving, setSaving] = useState(false);

  async function handleSubmit(values: Form.Values) {
    const deliverable = String(values.deliverable ?? "").trim();
    if (!deliverable) {
      await showToast({
        style: Toast.Style.Failure,
        title: "请写清楚要交付的成果",
        message: "例如「完成论文初稿」，而不是「阅读文献」",
      });
      return;
    }
    setSaving(true);
    const toast = await showToast({ style: Toast.Style.Animated, title: "正在创建任务笔记..." });
    try {
      const link = row.source === "dida" ? didaTaskUrl(row) : undefined;
      const ref = await createTaskNote(row.key, {
        taskTitle: row.title,
        taskLink: link,
        deliverable,
        purpose: String(values.purpose ?? ""),
        steps: String(values.steps ?? ""),
        project,
      });
      // 笔记链接写回滴答任务，在滴答里也能找到它（失败不影响主流程）
      if (row.source === "dida") {
        const line = `任务笔记：${noteUrl(ref.noteId)}`;
        await patchDidaTask(row, { content: row.content ? `${row.content}\n${line}` : line }).catch(() => undefined);
      }
      await syncProjectHome(project).catch(() => undefined);
      toast.style = Toast.Style.Success;
      toast.title = "已创建任务笔记";
      onDone(ref);
      pop();
    } catch (e) {
      setSaving(false);
      toast.style = Toast.Style.Failure;
      toast.title = "创建失败";
      toast.message = errMsg(e);
    }
  }

  return (
    <Form
      isLoading={saving}
      navigationTitle="创建任务笔记"
      actions={
        <ActionPanel>
          <Action.SubmitForm title="创建任务笔记" icon={Icon.Document} onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.Description title="任务" text={row.title} />
      <Form.TextField
        id="deliverable"
        title="交付成果"
        placeholder="这个任务最终要交付什么？（成果，不是动作）"
        defaultValue=""
        autoFocus
      />
      <Form.TextArea id="purpose" title="行动目的" placeholder="为什么要做？做完能解决什么？" />
      <Form.TextArea id="steps" title="行动步骤" placeholder="一行一步，会变成待勾选清单" />
      <Form.Description
        title="提示"
        text="任务笔记的单位是「要交付的成果」：「完成一篇可发表的论文初稿」是成果；「阅读文献」「学习分析方法」只是步骤。一个任务，一条笔记，围绕它汇聚资料、进展和复盘。"
      />
    </Form>
  );
}

/** 在任务笔记的「进展记录」里追加一条 */
export function ProgressForm({ noteId, title }: { noteId: string; title: string }) {
  const { pop } = useNavigation();
  const [saving, setSaving] = useState(false);

  async function handleSubmit(values: Form.Values) {
    const text = String(values.text ?? "").trim();
    if (!text) {
      await showToast({ style: Toast.Style.Failure, title: "请输入进展" });
      return;
    }
    setSaving(true);
    try {
      await appendProgress(noteId, text);
      await showToast({ style: Toast.Style.Success, title: "已记入任务笔记" });
      pop();
    } catch (e) {
      setSaving(false);
      await showToast({ style: Toast.Style.Failure, title: "保存失败", message: errMsg(e) });
    }
  }

  return (
    <Form
      isLoading={saving}
      navigationTitle={`记一条进展 · ${title}`}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="保存" icon={Icon.Check} onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextArea id="text" title="进展" placeholder="今天做了什么？卡在哪里？下一步是什么？" autoFocus />
    </Form>
  );
}

/** 完成待办并写复盘：有任务笔记就写进它的「复盘」，没有则单独存一条复盘笔记 */
export function ReviewForm({ row, project, noteId }: { row: TodoRow; project?: string; noteId?: string }) {
  const [saving, setSaving] = useState(false);

  async function handleSubmit(values: Form.Values) {
    const review = String(values.review ?? "").trim();
    setSaving(true);
    try {
      await completeRow(row);
      if (!review) {
        await showHUD("已完成");
      } else if (noteId) {
        await appendReview(noteId, review);
        await showHUD("已完成 · 复盘已写入任务笔记");
      } else {
        const tags = ["复盘", ...(project ? [project] : [])].map((t) => `#${t}`).join(" ");
        const text = `笔记 完成复盘：${row.title}\n\n${review}\n\n${tags}`;
        await showHUD(`已完成 · ${await runCapture({ text })}`);
      }
      await closeMainWindow({ clearRootSearch: true });
    } catch (error) {
      setSaving(false);
      await showToast({ style: Toast.Style.Failure, title: "保存失败", message: errMsg(error) });
    }
  }

  return (
    <Form
      isLoading={saving}
      navigationTitle="完成并复盘"
      actions={
        <ActionPanel>
          <Action.SubmitForm title="完成并保存复盘" icon={Icon.CheckCircle} onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.Description title="任务" text={row.title} />
      <Form.TextArea
        id="review"
        title="复盘"
        placeholder="交付了什么？效果如何？下次怎么调整？（留空则只标记完成）"
        autoFocus
      />
      <Form.Description
        title="保存到"
        text={noteId ? "这条任务的任务笔记 →「复盘」小节" : "没有任务笔记：会单独存一条带 #复盘 标签的笔记"}
      />
    </Form>
  );
}
