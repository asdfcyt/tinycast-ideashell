import AppKit
import SwiftUI

/// 财新 / 三联 / AI 日报（和今日信息里的这些条目）的右键菜单：和订阅文章同一套
struct ArticleMenu: View {
    let title: String
    let link: String
    var summary = ""

    var body: some View {
        let marks = ArticleMarks.shared
        let read = marks.isRead(link)
        Button(read ? "标为未读" : "标为已读") { marks.setRead(link, !read) }
        Button(FeedStore.shared.isStarred(link: link) ? "取消星标" : "加星标") {
            FeedStore.shared.toggleExternalStar(title: title, link: link, summary: summary)
        }
        Button("稍后读（存成待办）") { Task { await AppModel.current?.saveReadLater(title: title, link: link) } }
        if let u = URL(string: link) { Button("在浏览器中打开") { NSWorkspace.shared.open(u) } }
    }
}
