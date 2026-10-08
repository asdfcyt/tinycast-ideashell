import { Action, ActionPanel, Form, showToast, Toast, popToRoot } from "@raycast/api";
import { useState, useEffect } from "react";
import { createNote, listFolders, FolderInfo } from "./api";
import { getDefaultTags } from "./utils";

interface FormValues {
  title: string;
  body: string;
  tags: string;
  folder: string;
}

export default function Command() {
  const [folders, setFolders] = useState<FolderInfo[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    listFolders()
      .then((f) => setFolders(f))
      .catch(() => {})
      .finally(() => setIsLoading(false));
  }, []);

  async function handleSubmit(values: FormValues) {
    if (!values.body.trim()) {
      await showToast({ style: Toast.Style.Failure, title: "请输入笔记内容" });
      return;
    }

    const toast = await showToast({ style: Toast.Style.Animated, title: "正在创建笔记..." });

    try {
      const title = values.title.trim() || values.body.trim().slice(0, 30);
      const defaultTags = getDefaultTags();
      const userTags = values.tags
        ? values.tags
            .split(",")
            .map((t) => t.trim())
            .filter(Boolean)
        : [];
      const allTags = [...new Set([...defaultTags, ...userTags])];

      await createNote({
        title,
        body: values.body.trim(),
        tags: allTags.length > 0 ? allTags : undefined,
        folder: values.folder || undefined,
      });

      toast.style = Toast.Style.Success;
      toast.title = "✅ 笔记已创建";
      await popToRoot();
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "创建失败";
      toast.message = error instanceof Error ? error.message : String(error);
    }
  }

  return (
    <Form
      isLoading={isLoading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="创建笔记" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField id="title" title="标题" placeholder="留空则使用正文前30字" />
      <Form.TextArea id="body" title="正文" placeholder="写下你的灵感..." enableMarkdown />
      <Form.TextField id="tags" title="标签" placeholder="多个标签用逗号分隔" />
      <Form.Dropdown id="folder" title="文件夹" defaultValue="">
        <Form.Dropdown.Item value="" title="不指定文件夹" />
        {folders.map((f) => (
          <Form.Dropdown.Item key={f.id} value={f.name} title={`${f.emoji || "📁"} ${f.name}`} />
        ))}
      </Form.Dropdown>
    </Form>
  );
}
