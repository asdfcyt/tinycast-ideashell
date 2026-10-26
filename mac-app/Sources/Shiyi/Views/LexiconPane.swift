import SwiftUI

/// 设置窗口「词库」一页：热词（标签）+ 替换规则（听错 → 正确），改动即存
struct LexiconPane: View {
    @ObservedObject private var lexicon = VoiceLexicon.shared

    @State private var newHot = ""
    @State private var newFrom = ""
    @State private var newTo = ""
    @FocusState private var focus: Field?
    private enum Field { case hot, from, to }

    private var data: LexiconData { lexicon.data }

    var body: some View {
        SPage {
            SGroup("热词",
                   chip: ("\(data.hotwords.count) / \(VoiceLexicon.maxHotwords)", .gray),
                   footer: "人名、项目名、专业词。识别时优先听这些词，AI 整理时也会按它们修正同音字。需 2–10 个字，只能是文字或数字，不符合的会标成橙色、不会发给识别引擎。") {
                HStack(spacing: 8) {
                    TextField("添加热词，回车确认（可用顿号一次加多个）", text: $newHot)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .focused($focus, equals: .hot)
                        .onSubmit(addHot)
                    Button(action: addHot) { Image(systemName: "plus.circle.fill").font(.system(size: 16)) }
                        .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
                        .disabled(newHot.trimmed.isEmpty)
                }
                if data.hotwords.isEmpty {
                    Text("还没有热词").font(.system(size: 12)).foregroundStyle(.tertiary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(data.hotwords, id: \.self) { w in hotChip(w) }
                    }
                }
            }

            SGroup("替换规则",
                   chip: ("\(data.replacements.count) 条", .gray),
                   footer: "识别后无条件把「听错的词」换成「正确写法」。在预览里手改同音错字，也会自动记在这里。") {
                HStack(spacing: 8) {
                    TextField("听错的词", text: $newFrom)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .focused($focus, equals: .from)
                        .onSubmit { focus = .to }
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                    TextField("正确写法", text: $newTo)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .focused($focus, equals: .to)
                        .onSubmit(addRule)
                    Button(action: addRule) { Image(systemName: "plus.circle.fill").font(.system(size: 16)) }
                        .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
                        .disabled(newFrom.trimmed.isEmpty || newTo.trimmed.isEmpty)
                }
                if data.replacements.isEmpty {
                    Text("还没有替换规则").font(.system(size: 12)).foregroundStyle(.tertiary)
                } else {
                    ForEach(data.replacements, id: \.from) { r in ruleRow(r) }
                }
            }
        }
    }

    // MARK: 热词

    private func hotChip(_ w: String) -> some View {
        let valid = VoiceLexicon.isValidHotword(w)
        return HStack(spacing: 4) {
            Text(w).font(.system(size: 12.5))
            Button { removeHot(w) } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("删除")
        }
        .padding(.leading, 9).padding(.trailing, 7).padding(.vertical, 4)
        .foregroundStyle(valid ? Color.primary : Color.orange)
        .background((valid ? Color.accentColor : Color.orange).opacity(0.12), in: Capsule())
        .help(valid ? "" : "需要 2–10 个字、只能是文字或数字，这个词不会发给识别引擎")
    }

    private func addHot() {
        let words = VoiceLexicon.parseHotwords(newHot)
        guard !words.isEmpty else { return }
        var hot = data.hotwords
        for w in words where !hot.contains(w) { hot.append(w) }
        commit(hotwords: hot, rules: data.replacements)
        newHot = ""
        focus = .hot
    }

    private func removeHot(_ w: String) {
        commit(hotwords: data.hotwords.filter { $0 != w }, rules: data.replacements)
    }

    // MARK: 替换规则

    private func ruleRow(_ r: LexiconData.Rule) -> some View {
        HStack(spacing: 8) {
            Text(r.from).font(.system(size: 13)).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.tertiary)
            Text(r.to).font(.system(size: 13))
            Spacer(minLength: 8)
            Button { removeRule(r) } label: {
                Image(systemName: "minus.circle.fill").font(.system(size: 15))
            }
            .buttonStyle(.borderless).foregroundStyle(.tertiary).help("删除")
        }
    }

    private func addRule() {
        let f = newFrom.trimmed, t = newTo.trimmed
        guard !f.isEmpty, !t.isEmpty, f != t else { return }
        // 同一个错字再记一次就覆盖旧的
        var rules = data.replacements.filter { $0.from != f }
        rules.append(.init(from: f, to: t))
        commit(hotwords: data.hotwords, rules: rules)
        newFrom = ""; newTo = ""
        focus = .from
    }

    private func removeRule(_ r: LexiconData.Rule) {
        commit(hotwords: data.hotwords, rules: data.replacements.filter { $0.from != r.from })
    }

    private func commit(hotwords: [String], rules: [LexiconData.Rule]) {
        lexicon.save(hotwords: hotwords, replacements: rules.map { ($0.from, $0.to) })
    }
}
