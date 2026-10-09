import { Action, ActionPanel, Form, Icon, open, showToast, Toast, useNavigation } from "@raycast/api";
import { useState } from "react";
import { connectDida } from "./dida";

/** 连接滴答清单：在网页版滴答「设置 → 账户与安全 → API 口令」创建口令，粘贴到这里 */
export function DidaSetupForm({ onDone }: { onDone: () => Promise<void> | void }) {
  const { pop } = useNavigation();
  const [busy, setBusy] = useState(false);

  async function handleSubmit(values: Form.Values) {
    const token = String(values.token ?? "").trim();
    if (!token) {
      await showToast({ style: Toast.Style.Failure, title: "请粘贴 API 口令" });
      return;
    }
    setBusy(true);
    const toast = await showToast({ style: Toast.Style.Animated, title: "正在连接滴答清单..." });
    try {
      const r = await connectDida(token);
      if (r.missing.length > 0) {
        toast.style = Toast.Style.Failure;
        toast.title = "已连接，但缺少需要的工具";
        toast.message = r.missing.join("、");
      } else {
        toast.style = Toast.Style.Success;
        toast.title = "已连接滴答清单";
        toast.message = "带日期的待办会自动同步并提醒";
      }
      await onDone();
      pop();
    } catch (e) {
      setBusy(false);
      toast.style = Toast.Style.Failure;
      toast.title = "连接失败";
      toast.message = e instanceof Error ? e.message : String(e);
    }
  }

  return (
    <Form
      isLoading={busy}
      navigationTitle="连接滴答清单"
      actions={
        <ActionPanel>
          <Action.SubmitForm title="连接" icon={Icon.Link} onSubmit={handleSubmit} />
          <Action
            title="打开滴答清单网页版"
            icon={Icon.Globe}
            shortcut={{ modifiers: ["cmd"], key: "o" }}
            onAction={() => open("https://dida365.com")}
          />
          <Action
            title="打开官方 MCP 说明"
            icon={Icon.Document}
            onAction={() => open("https://help.dida365.com/articles/7438132116019216384")}
          />
        </ActionPanel>
      }
    >
      <Form.Description
        title="获取口令"
        text="网页版滴答清单 → 点击头像 → 设置 → 账户与安全 → API 口令 → 创建并复制。"
      />
      <Form.PasswordField id="token" title="API 口令" placeholder="粘贴口令（Bearer Token）" />
      <Form.Description
        title="说明"
        text="使用滴答清单官方 MCP（mcp.dida365.com）。口令只保存在本机；之后带日期的待办会自动同步到滴答并设置提醒。"
      />
    </Form>
  );
}
