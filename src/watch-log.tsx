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
import { addWatch } from "./watchlist";

/** 给关注项「记一条」：预填关键词，保存规则与 Smart Capture 相同（自动分流为待办 / Daily Note / 笔记） */
export function WatchLogForm({ keyword }: { keyword: string }) {
  const [saving, setSaving] = useState(false);

  async function handleSubmit(values: Form.Values) {
    const text = String(values.text ?? "").trim();
    if (!text || text === `${keyword}：`) {
      await showToast({ style: Toast.Style.Failure, title: "请输入内容" });
      return;
    }
    setSaving(true);
    try {
      await showHUD(await runCapture({ text }));
      await closeMainWindow({ clearRootSearch: true });
    } catch (error) {
      setSaving(false);
      await showToast({
        style: Toast.Style.Failure,
        title: "保存失败",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  return (
    <Form
      isLoading={saving}
      navigationTitle={`记一条 · ${keyword}`}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="保存" icon={Icon.Check} onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextArea
        id="text"
        title="内容"
        defaultValue={`${keyword}：`}
        placeholder="记点什么…（同样支持 待办 / 日记 / 笔记 前缀、#标签、@文件夹）"
        autoFocus
      />
    </Form>
  );
}

/** 新增关注项：输入关键词 / 标签 / 人名 / 项目名 */
export function WatchAddForm() {
  const { pop } = useNavigation();

  async function handleSubmit(values: Form.Values) {
    const keyword = String(values.keyword ?? "")
      .trim()
      .replace(/^[#@]+/, "");
    if (!keyword) {
      await showToast({ style: Toast.Style.Failure, title: "请输入关键词" });
      return;
    }
    const added = await addWatch(keyword);
    await showToast({
      style: added ? Toast.Style.Success : Toast.Style.Failure,
      title: added ? `已关注「${keyword}」` : `「${keyword}」已经在关注项里`,
    });
    if (added) pop();
  }

  return (
    <Form
      navigationTitle="新增关注项"
      actions={
        <ActionPanel>
          <Action.SubmitForm title="关注" icon={Icon.Pin} onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField id="keyword" title="关键词" placeholder="如：篆刻、洛神赋、体重、某个项目、某个人" autoFocus />
      <Form.Description
        title="说明"
        text="「什么算这件事」由这个关键词决定：笔记里出现它（或语义相近的检索结果里含它）就算一次提及。想换叫法可以取消后重新关注。"
      />
    </Form>
  );
}
