import {
  Action,
  ActionPanel,
  closeMainWindow,
  Form,
  Icon,
  LaunchProps,
  List,
  showHUD,
  showToast,
  Toast,
} from "@raycast/api";
import { useEffect } from "react";
import { createNote, warmUp } from "./api";
import { matchFolder } from "./capture-parse";
import { getFoldersFast, getFoldersFresh } from "./folders-cache";
import { buildTemplateNote, findTemplate, getTemplates, Template } from "./templates";
import { getDefaultTags, truncate } from "./utils";

const splitTags = (s: string) => [
  ...new Set(
    s
      .split(/[\s,，、]+/)
      .map((t) => t.replace(/^#+/, ""))
      .filter(Boolean),
  ),
];

async function saveTemplate(t: Template, values: Record<string, string>, extraTags: string[]): Promise<string> {
  const { title, body } = buildTemplateNote(t, values);

  let folderId: string | undefined;
  let folderNote = "";
  if (t.folderName) {
    let folder = matchFolder(t.folderName, await getFoldersFast());
    if (!folder) folder = matchFolder(t.folderName, await getFoldersFresh());
    if (folder) {
      folderId = folder.id;
      folderNote = ` 📁${folder.name}`;
    } else {
      folderNote = `（文件夹「${t.folderName}」不存在，已放在未归档）`;
    }
  }

  const tags = [...new Set([...getDefaultTags(), ...t.tags, ...extraTags])];
  await createNote({ title, body, tags: tags.length ? tags : undefined, folder: folderId, source: "tinycast" });
  return `✅ ${truncate(title, 24)} ${tags.map((x) => `#${x}`).join(" ")}${folderNote}`;
}

function TemplateForm({ template }: { template: Template }) {
  useEffect(() => {
    warmUp(); // 填表的时候先完成握手
  }, []);

  async function handleSubmit(values: Form.Values) {
    const strValues: Record<string, string> = {};
    template.fields.forEach((field, i) => {
      strValues[field.name] = String(values[`f${i}`] ?? "");
    });
    if (!template.fields.some((field) => strValues[field.name].trim())) {
      await showToast({ style: Toast.Style.Failure, title: "至少填写一项" });
      return;
    }

    // 先保存、再 HUD、最后关窗（先关窗会让 Tinycast 终止扩展，保存不会完成）
    const toast = await showToast({ style: Toast.Style.Animated, title: "正在保存..." });
    try {
      await showHUD(await saveTemplate(template, strValues, splitTags(String(values.extraTags ?? ""))));
      await closeMainWindow({ clearRootSearch: true });
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "保存失败";
      toast.message = error instanceof Error ? error.message : String(error);
    }
  }

  return (
    <Form
      navigationTitle={`模板录入 · ${template.name}`}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="保存" icon={Icon.Check} onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.Description
        title={template.name}
        text={`保存为「${template.name} 日期」，标签 ${[...getDefaultTags(), ...template.tags].map((t) => `#${t}`).join(" ") || "无"}${template.folderName ? `，文件夹 ${template.folderName}` : ""}`}
      />
      {template.fields.map((field, i) =>
        field.multiline ? (
          <Form.TextArea key={field.name} id={`f${i}`} title={field.name} autoFocus={i === 0} />
        ) : (
          <Form.TextField key={field.name} id={`f${i}`} title={field.name} autoFocus={i === 0} />
        ),
      )}
      <Form.Separator />
      <Form.TextField id="extraTags" title="额外标签" placeholder="#标签（可选，空格分隔）" />
    </Form>
  );
}

function TemplateList() {
  const templates = getTemplates();
  return (
    <List searchBarPlaceholder="选择模板…">
      {templates.map((t) => (
        <List.Item
          key={t.name}
          title={t.name}
          subtitle={t.fields.map((x) => x.name).join(" · ")}
          icon={Icon.List}
          accessories={[
            ...(t.tags.length ? [{ text: t.tags.map((x) => `#${x}`).join(" ") }] : []),
            ...(t.folderName ? [{ text: `@${t.folderName}` }] : []),
            ...(t.builtin ? [] : [{ tag: "自定义" }]),
          ]}
          actions={
            <ActionPanel>
              <Action.Push title="填写" icon={Icon.Pencil} target={<TemplateForm template={t} />} />
            </ActionPanel>
          }
        />
      ))}
      {templates.length === 0 && <List.EmptyView title="没有模板" description="在偏好设置的 Templates 里添加" />}
    </List>
  );
}

export default function Command(props: LaunchProps<{ arguments: { name?: string } }>) {
  const name = props.arguments?.name?.trim() ?? "";
  const found = name ? findTemplate(name) : undefined;
  return found ? <TemplateForm template={found} /> : <TemplateList />;
}
