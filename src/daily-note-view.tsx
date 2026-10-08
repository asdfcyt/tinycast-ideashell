import { Action, ActionPanel, Detail, List, showToast, Toast, Icon } from "@raycast/api";
import { useState, useEffect, useCallback } from "react";
import { getNoteDetail, NoteInfo, NoteDetail, getNoteId } from "./api";
import { listDailyNotes, extractDate, getDailyFolderName } from "./daily";
import { formatDate, formatDateTime } from "./utils";
import { useNoteDetails } from "./use-note-details";

const WEEKDAYS = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

function weekdayOf(date: string): string {
  const d = new Date(`${date}T00:00:00`);
  return Number.isNaN(d.getTime()) ? "" : WEEKDAYS[d.getDay()];
}

function buildMarkdown(title: string, body: string | undefined, loading: boolean): string {
  if (body === undefined) return `# ${title}\n\n${loading ? "加载中…" : "*（选中后加载内容）*"}`;
  return `# ${title}\n\n${body.trim() || "*（空白笔记）*"}`;
}

export default function Command() {
  const [notes, setNotes] = useState<NoteInfo[]>([]);
  const [folderFound, setFolderFound] = useState(true);
  const [isLoading, setIsLoading] = useState(true);
  const { details, loadingId, load, reset } = useNoteDetails();

  const loadDailyNotes = useCallback(async () => {
    setIsLoading(true);
    reset();
    try {
      const { notes: list, folder } = await listDailyNotes();
      setFolderFound(!!folder);
      setNotes(list);
      if (list.length > 0) load(getNoteId(list[0]));
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "加载失败",
        message: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setIsLoading(false);
    }
  }, [load, reset]);

  useEffect(() => {
    loadDailyNotes();
  }, [loadDailyNotes]);

  const todayDate = formatDate(new Date());

  return (
    <List
      isLoading={isLoading}
      isShowingDetail={notes.length > 0}
      searchBarPlaceholder="搜索 Daily Note（日期或内容）..."
      onSelectionChange={(id) => load(id)}
    >
      {notes.map((note) => {
        const noteId = getNoteId(note);
        const dateStr = extractDate(note.title);
        const isToday = dateStr === todayDate;
        const detail = details[noteId];
        const body = detail ? detail.content || detail.body || "" : undefined;

        return (
          <List.Item
            key={noteId}
            id={noteId}
            title={note.title}
            // 把正文放进 keywords，让搜索栏可以按内容过滤已加载的笔记
            keywords={body ? [body] : undefined}
            icon={isToday ? { source: Icon.Calendar, tintColor: "#007AFF" } : Icon.Document}
            accessories={[
              ...(isToday ? [{ tag: { value: "今天", color: "#007AFF" } }] : []),
              ...(dateStr ? [{ text: weekdayOf(dateStr) }] : []),
            ]}
            detail={
              <List.Item.Detail
                isLoading={loadingId === noteId}
                markdown={buildMarkdown(note.title, body, loadingId === noteId)}
                metadata={
                  detail ? (
                    <List.Item.Detail.Metadata>
                      {dateStr && (
                        <List.Item.Detail.Metadata.Label title="日期" text={`${dateStr} ${weekdayOf(dateStr)}`} />
                      )}
                      {detail.created_at && (
                        <List.Item.Detail.Metadata.Label title="创建时间" text={formatDateTime(detail.created_at)} />
                      )}
                      {detail.tags && detail.tags.length > 0 && (
                        <List.Item.Detail.Metadata.TagList title="标签">
                          {detail.tags.map((t) => (
                            <List.Item.Detail.Metadata.TagList.Item key={t} text={t} />
                          ))}
                        </List.Item.Detail.Metadata.TagList>
                      )}
                    </List.Item.Detail.Metadata>
                  ) : undefined
                }
              />
            }
            actions={
              <ActionPanel>
                <Action.Push
                  title="查看全文"
                  icon={Icon.Eye}
                  target={<DailyNoteDetail noteId={noteId} title={note.title} />}
                />
                {body && (
                  <Action.CopyToClipboard
                    title="复制正文"
                    content={body}
                    shortcut={{ modifiers: ["cmd"], key: "c" }}
                  />
                )}
                <Action
                  title="刷新列表"
                  icon={Icon.ArrowClockwise}
                  shortcut={{ modifiers: ["cmd"], key: "r" }}
                  onAction={loadDailyNotes}
                />
              </ActionPanel>
            }
          />
        );
      })}
      {notes.length === 0 && !isLoading && (
        <List.EmptyView
          title={folderFound ? "文件夹里还没有 Daily Note" : `没有找到「${getDailyFolderName()}」文件夹`}
          description={
            folderFound
              ? "使用 Daily Note 命令开始记录今天的第一条"
              : "请在插件偏好设置里检查 Daily Note Folder 名称，或先用 Daily Note 命令创建"
          }
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

  const noteBody = detail ? detail.content || detail.body || "" : "";

  return (
    <Detail
      isLoading={isLoading}
      markdown={buildMarkdown(detail?.title || title, detail ? noteBody : undefined, isLoading)}
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
            {detail.created_at && (
              <Detail.Metadata.Label title="创建时间" text={formatDateTime(detail.created_at)} />
            )}
          </Detail.Metadata>
        ) : undefined
      }
      actions={
        <ActionPanel>
          {noteBody && (
            <Action.CopyToClipboard
              title="复制正文"
              content={noteBody}
              shortcut={{ modifiers: ["cmd"], key: "c" }}
            />
          )}
        </ActionPanel>
      }
    />
  );
}
