import { Action, ActionPanel, Detail, showToast, Toast } from "@raycast/api";
import { useEffect, useState } from "react";
import { getNoteDetail, NoteDetail } from "./api";
import { buildNoteMarkdown, formatDateTime } from "./utils";

/** 笔记全文页：标题 → 摘要 → 正文，右侧元信息显示创建时间和标签 */
export function NoteDetailView({ noteId, title, summary }: { noteId: string; title: string; summary?: string }) {
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
  const finalSummary = detail?.summary || summary;

  return (
    <Detail
      isLoading={isLoading}
      markdown={buildNoteMarkdown({
        title: detail?.title || title,
        summary: finalSummary,
        body: detail ? noteBody : undefined,
        loading: isLoading,
      })}
      metadata={
        detail ? (
          <Detail.Metadata>
            {detail.created_at && <Detail.Metadata.Label title="创建时间" text={formatDateTime(detail.created_at)} />}
            {detail.tags && detail.tags.length > 0 && (
              <Detail.Metadata.TagList title="标签">
                {detail.tags.map((tag) => (
                  <Detail.Metadata.TagList.Item key={tag} text={tag} />
                ))}
              </Detail.Metadata.TagList>
            )}
          </Detail.Metadata>
        ) : undefined
      }
      actions={
        <ActionPanel>
          {noteBody && (
            <Action.CopyToClipboard title="复制正文" content={noteBody} shortcut={{ modifiers: ["cmd"], key: "c" }} />
          )}
          {finalSummary && (
            <Action.CopyToClipboard
              title="复制摘要"
              content={finalSummary}
              shortcut={{ modifiers: ["cmd", "opt"], key: "c" }}
            />
          )}
          <Action.CopyToClipboard
            title="复制标题"
            content={detail?.title || title}
            shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
          />
        </ActionPanel>
      }
    />
  );
}
