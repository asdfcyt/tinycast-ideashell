import { Action, ActionPanel, Form, getSelectedFinderItems, popToRoot, showHUD, showToast, Toast } from "@raycast/api";
import path from "path";
import { useEffect, useState } from "react";
import { createNote, FolderInfo, listFolders } from "./api";
import { prepareFiles, summarize } from "./attachments";
import { getDefaultTags, truncate } from "./utils";

interface FormValues {
  files: string[];
  title: string;
  body: string;
  tags: string;
  folder: string;
}

export default function Command() {
  const [files, setFiles] = useState<string[]>([]);
  const [folders, setFolders] = useState<FolderInfo[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    // 预填 Finder 中当前选中的文件；没有选中或读取失败就让用户自己选
    Promise.all([
      getSelectedFinderItems()
        .then((items) => setFiles(items.map((i) => i.path)))
        .catch(() => {}),
      listFolders()
        .then(setFolders)
        .catch(() => {}),
    ]).finally(() => setIsLoading(false));
  }, []);

  async function handleSubmit(values: FormValues) {
    const picked = values.files ?? [];
    if (picked.length === 0) {
      await showToast({ style: Toast.Style.Failure, title: "请先选择文件" });
      return;
    }

    const toast = await showToast({ style: Toast.Style.Animated, title: "正在处理文件..." });
    try {
      const prepared = await prepareFiles(picked);
      const names = [...prepared.images, ...prepared.audios, ...prepared.documents].map((a) => a.name);
      if (names.length === 0) {
        throw new Error(
          prepared.skipped.length ? `没有可上传的文件：${prepared.skipped.join("；")}` : "没有可上传的文件",
        );
      }

      const firstName = path.basename(names[0], path.extname(names[0]));
      const title = truncate(
        values.title.trim() || (names.length > 1 ? `${firstName} 等 ${names.length} 个文件` : firstName),
        30,
      );
      const body = values.body.trim();
      const tags = [
        ...new Set([
          ...getDefaultTags(),
          ...values.tags
            .split(/[,，\s]+/)
            .map((t) => t.trim())
            .filter(Boolean),
        ]),
      ];

      const base = {
        title,
        tags: tags.length ? tags : undefined,
        folder: values.folder || undefined,
        source: "tinycast",
        images: prepared.images,
        audios: prepared.audios,
        documents: prepared.documents,
      };
      // 只有图片/音频时正文可以为空；带文档时补一行附件清单，避免接口要求必须有正文
      const fallbackBody = prepared.documents.length > 0 ? `附件：${names.join("、")}` : undefined;

      toast.title = `正在上传 ${names.length} 个文件...`;
      try {
        await createNote({ ...base, body: body || fallbackBody });
      } catch (e) {
        // 接口提示缺少正文时，补上附件清单重试一次
        if (!body && !fallbackBody && /content/i.test(e instanceof Error ? e.message : String(e))) {
          await createNote({ ...base, body: `附件：${names.join("、")}` });
        } else {
          throw e;
        }
      }

      toast.hide();
      const skipped = prepared.skipped.length ? `（跳过 ${prepared.skipped.length} 个）` : "";
      await showHUD(`✅ 已保存 ${names.length} 个文件到闪念贝壳${skipped}`);
      await popToRoot();
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "保存失败";
      toast.message = error instanceof Error ? error.message : String(error);
    }
  }

  const summary = summarize(files);

  return (
    <Form
      isLoading={isLoading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="保存到闪念贝壳" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.FilePicker id="files" title="文件" value={files} onChange={setFiles} canChooseDirectories={false} />
      <Form.Description
        title="识别结果"
        text={summary || "支持图片、音频（mp3/m4a/wav/aac）、PDF/Word/Excel/PPT 及 txt/md/csv 等文本文件"}
      />
      <Form.Separator />
      <Form.TextField id="title" title="标题" placeholder="留空则使用首个文件名" />
      <Form.TextArea id="body" title="备注" placeholder="可选：为这些文件写点说明（会参与搜索）" />
      <Form.TextField id="tags" title="标签" placeholder="多个标签用逗号分隔" />
      <Form.Dropdown id="folder" title="文件夹" defaultValue="">
        <Form.Dropdown.Item value="" title="不指定文件夹" />
        {folders.map((f) => (
          <Form.Dropdown.Item key={f.id} value={f.id} title={`${f.emoji || "📁"} ${f.name}`} />
        ))}
      </Form.Dropdown>
    </Form>
  );
}
