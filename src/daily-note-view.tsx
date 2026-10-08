import { Action, ActionPanel, Detail, List, showToast, Toast, Icon } from "@raycast/api";
import { useState, useEffect, useCallback } from "react";
import { searchNotes, getNoteDetail, NoteInfo, NoteDetail, getNoteId } from "./api";
import { getDailyNoteTitle, formatDate } from "./utils";

export default function Command() {
  const [notes, setNotes] = useState<NoteInfo[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  const loadDailyNotes = useCallback(async () => {
    setIsLoading(true);
    try {
      const results = await searchNotes("Daily Note");
      const dailyNotes = results
        .filter((n) => n.title && /\d{4}-\d{2}-\d{2}/.test(n.title))
        .sort((a, b) => {
          const dateA = a.title.match(/\d{4}-\d{2}-\d{2}/)?.[0] || "";
          const dateB = b.title.match(/\d{4}-\d{2}-\d{2}/)?.[0] || "";
          return dateB.localeCompare(dateA);
        });
      setNotes(dailyNotes);
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "加载失败",
        message: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    loadDailyNotes();
  }, [loadDailyNotes]);

  const todayTitle = getDailyNoteTitle();
  const todayDate = formatDate(new Date());

  return (
    <List isLoading={isLoading} searchBarPlaceholder="搜索 Daily Note...">
      <List.Section title="Daily Notes">
        {notes.map((note, index) => {
          const noteId = getNoteId(note);
          const dateMatch = note.title.match(/\d{4}-\d{2}-\d{2}/);
          const dateStr = dateMatch ? dateMatch[0] : "";
          const isToday = dateStr === todayDate;

          return (
            <List.Item
              key={noteId || `note-${index}`}
              title={note.title}
              subtitle={note.summary || ""}
              icon={isToday ? Icon.Calendar : Icon.Document}
              accessories={[
                ...(isToday ? [{ tag: { value: "今天", color: "#007AFF" } }] : []),
                ...(note.tags
                  ? note.tags.map((t) => ({ tag: t }))
                  : []),
              ]}
              actions={
                <ActionPanel>
                  {noteId && (
                    <Action.Push
                      title="查看详情"
                      icon={Icon.Eye}
                      target={<DailyNoteDetail noteId={noteId} title={note.title} />}
                    />
                  )}
                </ActionPanel>
              }
            />
          );
        })}
      </List.Section>
      {notes.length === 0 && !isLoading && (
        <List.EmptyView
          title="没有找到 Daily Note"
          description="使用 Daily Note 命令开始记录你的第一篇日记"
          icon={Icon.Calendar}
        />
      )}
    </List>
  );
}

function DailyNoteDetail({ noteId, title }: { noteId: string; title: string }) {
  const [detail, setDetail] = useState<NoteDetail | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    getNoteDetail(noteId)
      .then(setDetail)
      .catch(async (err) => {
        await showToast({
          style: Toast.Style.Failure,
          title: "加载详情失败",
          message: err instanceof Error ? err.message : String(err),
        });
      })
      .finally(() => setIsLoading(false));
  }, [noteId]);

  const noteBody = detail ? (detail.content || detail.body || "") : "";
  const markdown = detail
    ? `# ${detail.title}\n\n${noteBody || "*（空白笔记）*"}`
    : `# ${title}\n\n加载中...`;

  return (
    <Detail
      isLoading={isLoading}
      markdown={markdown}
      metadata={
        detail ? (
          <Detail.Metadata>
            {detail.tags && detail.tags.length > 0 && (
              <Detail.Metadata.TagList title="标签">
                {detail.tags.map((tag) => (
                  <Detail.Metadata.TagList.Item key={tag} text={tag} />
                ))}
              </Detail.Metadata.TagList>
            )}
            {detail.folder && <Detail.Metadata.Label title="文件夹" text={detail.folder} />}
            {detail.createdAt && <Detail.Metadata.Label title="创建时间" text={detail.createdAt} />}
            {detail.updatedAt && <Detail.Metadata.Label title="更新时间" text={detail.updatedAt} />}
          </Detail.Metadata>
        ) : undefined
      }
    />
  );
}
