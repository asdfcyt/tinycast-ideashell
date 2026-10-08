import {
  Alert,
  Action,
  ActionPanel,
  closeMainWindow,
  confirmAlert,
  Form,
  Icon,
  LaunchProps,
  List,
  showHUD,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useCallback, useEffect, useState } from "react";
import { createNote, warmUp } from "./api";
import { matchFolder } from "./capture-parse";
import { getFoldersFast, getFoldersFresh } from "./folders-cache";
import {
  buildTemplate,
  buildTemplateNote,
  deleteLocalTemplate,
  fieldsToText,
  findTemplate,
  loadTemplates,
  saveLocalTemplate,
  Template,
} from "./templates";
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

/** 新建 / 编辑模板：每行一个字段，字段名后加 + 表示多行输入框 */
function TemplateEditor({ initial, onSaved }: { initial?: Template; onSaved: () => void }) {
  const { pop } = useNavigation();
  const editing = initial?.source === "local" ? initial.name : undefined;

  async function handleSubmit(values: Form.Values) {
    const t = buildTemplate({
      name: String(values.name ?? ""),
      fieldsText: String(values.fields ?? ""),
      tags: String(values.tags ?? ""),
      folderName: String(values.folder ?? ""),
    });
    if (!t) {
      await showToast({ style: Toast.Style.Failure, title: "请填写模板名称，并至少写一个字段" });
      return;
    }
    await saveLocalTemplate(t, editing);
    await showToast({ style: Toast.Style.Success, title: `已保存模板「${t.name}」` });
    onSaved();
    pop();
  }

  return (
    <Form
      navigationTitle={editing ? `编辑模板 · ${editing}` : "新建模板"}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="保存模板" icon={Icon.Check} onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="name"
        title="模板名称"
        placeholder="如：刻印、体重、会议"
        defaultValue={initial?.name ?? ""}
      />
      <Form.TextArea
        id="fields"
        title="字段"
        placeholder={"每行一个字段；字段名后加 + 为多行输入框\n例如：\n作品\n印文\n感受+\n问题+"}
        defaultValue={initial ? fieldsToText(initial) : ""}
      />
      <Form.TextField
        id="tags"
        title="标签"
        placeholder="#篆刻 #练习（可选）"
        defaultValue={(initial?.tags ?? []).map((t) => `#${t}`).join(" ")}
      />
      <Form.TextField
        id="folder"
        title="文件夹"
        placeholder="保存到哪个文件夹（可选，写文件夹名）"
        defaultValue={initial?.folderName ?? ""}
      />
      <Form.Description
        title="说明"
        text="保存后的笔记标题为「模板名 日期」，正文每项一段「字段：值」，模板标签写在正文末尾。"
      />
    </Form>
  );
}

function TemplateList({ templates, loading, reload }: { templates: Template[]; loading: boolean; reload: () => void }) {
  async function remove(t: Template) {
    if (
      await confirmAlert({
        title: `删除模板「${t.name}」？`,
        message: "已保存的笔记不受影响。",
        primaryAction: { title: "删除", style: Alert.ActionStyle.Destructive },
      })
    ) {
      await deleteLocalTemplate(t.name);
      reload();
    }
  }

  const newAction = (
    <Action.Push
      title="新建模板"
      icon={Icon.Plus}
      shortcut={{ modifiers: ["cmd"], key: "n" }}
      target={<TemplateEditor onSaved={reload} />}
    />
  );

  return (
    <List isLoading={loading} searchBarPlaceholder="选择模板…">
      {templates.map((t) => (
        <List.Item
          key={t.name}
          title={t.name}
          subtitle={t.fields.map((x) => x.name).join(" · ")}
          icon={Icon.List}
          accessories={[
            ...(t.tags.length ? [{ text: t.tags.map((x) => `#${x}`).join(" ") }] : []),
            ...(t.folderName ? [{ text: `@${t.folderName}` }] : []),
            ...(t.source === "builtin" ? [] : [{ tag: t.source === "local" ? "自定义" : "偏好设置" }]),
          ]}
          actions={
            <ActionPanel>
              <Action.Push title="填写" icon={Icon.Pencil} target={<TemplateForm template={t} />} />
              {newAction}
              {t.source === "local" ? (
                <>
                  <Action.Push
                    title="编辑模板"
                    icon={Icon.Gear}
                    shortcut={{ modifiers: ["cmd"], key: "e" }}
                    target={<TemplateEditor initial={t} onSaved={reload} />}
                  />
                  <Action
                    title="删除模板"
                    icon={Icon.Trash}
                    shortcut={{ modifiers: ["ctrl"], key: "x" }}
                    onAction={() => remove(t)}
                  />
                </>
              ) : (
                <Action.Push
                  title={t.source === "builtin" ? "基于此模板新建（可覆盖内置）" : "基于此模板新建"}
                  icon={Icon.Gear}
                  shortcut={{ modifiers: ["cmd"], key: "e" }}
                  target={<TemplateEditor initial={t} onSaved={reload} />}
                />
              )}
            </ActionPanel>
          }
        />
      ))}
      {!loading && templates.length === 0 && (
        <List.EmptyView
          title="还没有模板"
          description="按 ⌘N 新建模板"
          actions={<ActionPanel>{newAction}</ActionPanel>}
        />
      )}
    </List>
  );
}

export default function Command(props: LaunchProps<{ arguments: { name?: string } }>) {
  const name = props.arguments?.name?.trim() ?? "";
  const [templates, setTemplates] = useState<Template[]>([]);
  const [loading, setLoading] = useState(true);

  const reload = useCallback(() => {
    loadTemplates()
      .then(setTemplates)
      .finally(() => setLoading(false));
  }, []);
  useEffect(reload, [reload]);

  const found = name && !loading ? findTemplate(name, templates) : undefined;
  if (name && loading) return <List isLoading />;
  return found ? (
    <TemplateForm template={found} />
  ) : (
    <TemplateList templates={templates} loading={loading} reload={reload} />
  );
}
