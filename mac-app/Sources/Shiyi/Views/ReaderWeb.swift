import AppKit
import SwiftUI
import WebKit

/*
 * 阅读页右边的内嵌浏览器：加载财新的文章页，你自己扫码登录（登录状态留在本机），读的就是你订阅的内容。
 * 「重排版」只是在页面上叠一层样式：藏掉导航 / 广告，把正文排成窄栏大字号（纸张 / 白 / 深色）；
 * 页面本身的脚本照常跑（登录后才下发的全文、分页都不受影响），不抓取、不保存任何正文。
 */

@MainActor
final class ReaderController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let shared = ReaderController()

    let webView: WKWebView
    private let ucc: WKUserContentController

    @Published var loading = false
    @Published var canGoBack = false
    @Published var url: URL?
    /// 当前页是不是财新文章页（才套阅读样式）
    @Published var article = false
    /// 文章页只给了预览（没登录 / 没订阅周刊）
    @Published var locked = false
    @Published var loggedIn = false
    @Published var onLogin = false
    // 阅读排版（都存在本机，改了立刻作用到当前页）
    @Published var size: Double { didSet { save(size, "size") } }
    /// paper / white / dark
    @Published var theme: String { didSet { save(theme, "theme") } }
    /// song 宋体 / hei 黑体 / kai 楷体
    @Published var font: String { didSet { save(font, "font") } }
    /// 行距（倍数）
    @Published var leading: Double { didSet { save(leading, "leading") } }
    /// 正文栏宽（px）
    @Published var width: Double { didSet { save(width, "width") } }
    /// 段首空两格（页面自带的全角空格会先去掉，由样式统一排）
    @Published var indent: Bool { didSet { save(indent, "indent") } }
    /// 两端对齐
    @Published var justify: Bool { didSet { save(justify, "justify") } }

    /// 页面里当前选中的文字（右键菜单用）
    private(set) var selection = ""

    private func save(_ v: Any, _ key: String) {
        UserDefaults.standard.set(v, forKey: "reader." + key)
        push()
    }

    /// 恢复出厂的排版
    func resetTypography() {
        size = 19; font = "song"; leading = 1.95; width = 680; indent = true; justify = true
    }

    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    override init() {
        let ud = UserDefaults.standard
        let d = ud.double(forKey: "reader.size")
        size = d >= 14 ? d : 19
        theme = ud.string(forKey: "reader.theme") ?? "paper"
        font = ud.string(forKey: "reader.font") ?? "song"
        let l = ud.double(forKey: "reader.leading")
        leading = l >= 1.4 ? l : 1.95
        let w = ud.double(forKey: "reader.width")
        width = w >= 480 ? w : 680
        indent = ud.object(forKey: "reader.indent") as? Bool ?? true
        justify = ud.object(forKey: "reader.justify") as? Bool ?? true
        let uc = WKUserContentController()
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.userContentController = uc
        ucc = uc
        let wv = ReaderWKWebView(frame: .zero, configuration: cfg)
        webView = wv
        super.init()
        wv.controller = self
        webView.customUserAgent = Self.ua
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        ucc.add(self, name: "reader")
        installScript()
    }

    // MARK: 操作

    /// 每次从目录 / 列表点进来的那一页算「起点」：返回键只在起点之后的页面之间退，不会退回别的来源打开过的页面
    private var root: WKBackForwardListItem?
    private var pendingRoot = false

    private func updateBack() {
        let cur = webView.backForwardList.currentItem
        canGoBack = webView.canGoBack && root != nil && cur !== root
    }

    func open(_ u: URL) {
        url = u
        root = nil
        pendingRoot = true
        canGoBack = false
        webView.load(URLRequest(url: u))
    }

    /// 去财新登录页（登录完会回到 `back`）
    func openLogin(back: URL? = nil) {
        let target = back ?? webView.url ?? URL(string: "https://weekly.caixin.com/")!
        let enc = target.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        if let u = URL(string: "https://u.caixin.com/web/login?url=" + enc) { open(u) }
    }

    func goBack() { if canGoBack { webView.goBack() } }
    func openInBrowser() { if let u = webView.url { NSWorkspace.shared.open(u) } }

    /// 退出登录：清掉本机上财新的登录状态
    func logout() async {
        let store = webView.configuration.websiteDataStore
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records.filter { $0.displayName.contains("caixin") })
        await refreshLogin()
        if article { webView.reload() }
    }

    func refreshLogin() async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let on = cookies.contains { $0.domain.contains("caixin.com") && ["SA_USER_UID", "USER_LOGIN_CODE"].contains($0.name) && !$0.value.isEmpty }
        if loggedIn != on { loggedIn = on }
    }

    /// 选中的文字放进一张新便签（带出处链接），读到好句子随手摘下来
    func clipSelectionToSticky() async {
        let r = try? await webView.evaluateJavaScript("window.getSelection().toString()")
        let sel = ((r as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sel.isEmpty else {
            AppModel.current?.showNotice("先在文章里选中要摘录的文字")
            return
        }
        let quote = sel.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        var text = quote
        if let u = webView.url {
            let title = (webView.title ?? u.host ?? "原文").replacingOccurrences(of: "最新财新周刊｜", with: "")
            text += "\n\n[\(title)](\(u.absoluteString))"
        }
        StickyController.shared.create(text: text)
    }

    // MARK: 阅读样式

    private func installScript() {
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: Self.script(settings: settingsJSON), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    private var settingsJSON: String {
        let d: [String: Any] = ["size": size, "theme": theme, "font": font, "leading": leading, "width": width, "indent": indent, "justify": justify]
        let data = (try? JSONSerialization.data(withJSONObject: d)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// 排版变了：下次打开的页面用新值，当前页立刻更新
    private func push() {
        installScript()
        webView.evaluateJavaScript("window.__syReader && window.__syReader.set(\(settingsJSON))", completionHandler: nil)
    }

    /*
     * 阅读样式（参考 Mozilla Readability / 赫蹏 Heti / pangu.js 的思路，但不引入它们的脚本）：
     * · 中英文间距：WebKit 的 `text-autospace`（比手敲空格更窄的 1/8 字宽间距）
     * · 避头尾：`line-break: strict`；两端对齐用 `text-justify: inter-character`
     * · 段首空两格：先去掉页面自带的全角空格，再用 `text-indent: 2em` 统一排
     * · 小标题（整段加粗的短句）、署名行单独成样式
     */
    private static func script(settings: String) -> String {
        #"""
        (function () {
          if (window.__syReader) { return; }
          var R = window.__syReader = \#(settings);
          var T = { paper: ['#f4eee0', '#2c2a24', '#8a5a14'], white: ['#ffffff', '#1d1d1f', '#a8560a'], dark: ['#1b1b1d', '#d6d2c9', '#e9a84c'] };
          var F = {
            song: '"Songti SC","Source Han Serif SC","Noto Serif CJK SC",serif',
            hei: '"PingFang SC","Source Han Sans SC","Noto Sans CJK SC",sans-serif',
            kai: '"Kaiti SC","STKaiti","KaiTi",serif'
          };
          var isAI = location.hostname === 'aihot.news';
          var isLW = /(^|\.)lifeweek\.com\.cn$/.test(location.hostname) && /^\/h5\/article\/detail\.do/.test(location.pathname);
          var content = isAI ? document.querySelector('main article') : isLW ? document.querySelector('.area6') : document.getElementById('the_content');
          var isArticle = (isAI || isLW) ? !!content : (/^\/\d{4}-\d{2}-\d{2}\/\d+\.html/.test(location.pathname) && !!content);
          function post(o) {
            try { window.webkit.messageHandlers.reader.postMessage(o); } catch (e) {}
          }
          // 不少站点会拦截右键 / 选择 / 复制：在最前面（捕获阶段）截住，让自带菜单和选择能用
          ['contextmenu', 'selectstart', 'copy', 'cut', 'dragstart'].forEach(function (t) {
            window.addEventListener(t, function (e) { e.stopImmediatePropagation(); }, true);
          });
          try { document.oncontextmenu = null; document.onselectstart = null; document.oncopy = null; } catch (e) {}
          // 选中的文字同步给原生（右键菜单用）
          var selTimer = null;
          document.addEventListener('selectionchange', function () {
            clearTimeout(selTimer);
            selTimer = setTimeout(function () { post({ sel: String(window.getSelection()).slice(0, 6000) }); }, 120);
          });
          // AIHOT 的条目页 / 日报页：只留 <article>，藏掉导航栏、侧栏、底部工具条
          function cssAI() {
            var c = T[R.theme] || T.paper, bg = c[0], fg = c[1], ac = c[2], H = 'html.sy-r ';
            var ff = F[R.font] || F.song, A = H + '.sy-root';
            var txt = A + ' p,' + A + ' li,' + A + ' blockquote,' + A + ' td,' + A + ' th,' + A + ' dd,' + A + ' dt';
            return [
              H + ',html.sy-r body{background:' + bg + ' !important;color:' + fg + ' !important;min-width:0 !important;margin:0 !important}',
              H + '.sy-hide{display:none !important}',
              // 站点自己的手机顶栏（「‹ 精选」）、侧栏、底部工具条：用样式藏，不怕页面重渲染时把标记冲掉
              H + 'aside,' + H + 'header[data-phone-bar],' + H + 'nav[aria-label="阅读工具"],' + H + 'nav[aria-label="主导航"]{display:none !important}',
              A + '{display:block !important;max-width:' + R.width + 'px !important;margin:0 auto !important;padding:40px 28px 90px !important;box-sizing:border-box;color:' + fg + ' !important}',
              A + ' *{background:none !important;box-shadow:none !important;-webkit-user-select:text !important;user-select:text !important;text-autospace:ideograph-alpha ideograph-numeric;line-break:strict;overflow-wrap:break-word}',
              A + ' *:not(a):not(code):not(pre){color:' + fg + ' !important}',
              A + ' h1,' + A + ' h2,' + A + ' h3,' + A + ' h4{font-family:' + (R.font === 'kai' ? F.kai : F.hei) + ' !important;font-weight:700 !important;line-height:1.4 !important;margin:1.5em 0 .6em !important}',
              A + ' h1{font-size:' + (R.size * 1.55) + 'px !important;margin-top:0 !important}',
              A + ' h2{font-size:' + (R.size * 1.3) + 'px !important}',
              A + ' h3,' + A + ' h4{font-size:' + (R.size * 1.12) + 'px !important}',
              txt + '{font-family:' + ff + ' !important;font-size:' + R.size + 'px !important;line-height:' + R.leading + ' !important;text-align:' + (R.justify ? 'justify' : 'left') + ';text-justify:inter-character;text-wrap:pretty}',
              A + ' p{margin:0 0 .95em !important}',
              A + ' a{color:' + ac + ' !important;text-decoration:none !important}',
              A + ' pre,' + A + ' code{font-family:ui-monospace,Menlo,monospace !important;font-size:' + (R.size * 0.82) + 'px !important;line-height:1.6 !important;background:rgba(127,127,127,.14) !important;border-radius:5px}',
              A + ' pre{padding:12px 14px !important;overflow-x:auto}',
              A + ' code{padding:1px 5px}',
              A + ' img{max-width:100% !important;height:auto !important;border-radius:6px}',
              A + ' nav,' + A + ' button{font-size:13px !important;opacity:.75}'
            ].join('\n');
          }
          // 三联中读手机版文章页：只留 .area6（标题、作者行、导语、正文）
          function cssLW() {
            var c = T[R.theme] || T.paper, bg = c[0], fg = c[1], ac = c[2], H = 'html.sy-r ';
            var ff = F[R.font] || F.song, A = H + '.area6', B = A + ' .bd';
            return [
              H + ',html.sy-r body{background:' + bg + ' !important;color:' + fg + ' !important;min-width:0 !important;margin:0 !important}',
              H + '.sy-hide,' + H + '.header,' + H + '.area4,' + H + '.mask2{display:none !important}',
              A + '{display:block !important;max-width:' + R.width + 'px !important;margin:0 auto !important;padding:40px 28px 90px !important;box-sizing:border-box;background:none !important;width:auto !important;float:none !important}',
              A + ' *{box-sizing:border-box;-webkit-user-select:text !important;user-select:text !important}',
              A + ' .cap1{font:700 ' + (R.size * 1.55) + 'px/1.4 ' + (R.font === 'kai' ? F.kai : F.hei) + ' !important;color:' + fg + ' !important;margin:0 0 12px !important;text-align:left !important}',
              A + ' .p_sj,' + A + ' .p_sj *{font-size:13px !important;color:' + fg + ' !important;opacity:.65;background:none !important}',
              A + ' .d_zy{font-size:' + (R.size * 0.9) + 'px !important;line-height:1.7 !important;color:' + fg + ' !important;opacity:.78;margin:6px 0 18px !important;padding:0 0 0 12px !important;border-left:3px solid ' + ac + ' !important;background:none !important}',
              B + ',' + B + ' *{font-family:' + ff + ' !important;font-size:' + R.size + 'px !important;line-height:' + R.leading + ' !important;color:' + fg + ' !important;background:none !important;letter-spacing:normal !important;text-autospace:ideograph-alpha ideograph-numeric;line-break:strict;overflow-wrap:break-word;text-wrap:pretty}',
              B + ' p{margin:0 0 ' + (R.indent ? '.55em' : '.95em') + ' !important}',
              B + ' p:not([style*="center"]){text-indent:' + (R.indent ? '2em' : '0') + ' !important;text-align:' + (R.justify ? 'justify' : 'left') + '}',
              B + ' section{margin-left:0 !important;margin-right:0 !important}',
              B + ' strong,' + B + ' b{font-weight:700 !important}',
              B + ' a{color:' + ac + ' !important;text-decoration:none}',
              B + ' img{max-width:100% !important;height:auto !important;border-radius:6px}',
              B + ' blockquote{border-left:3px solid ' + ac + ';margin:1em 0;padding:0 0 0 14px}'
            ].join('\n');
          }
          function css() {
            if (isAI) { return cssAI(); }
            if (isLW) { return cssLW(); }
            var c = T[R.theme] || T.paper, bg = c[0], fg = c[1], ac = c[2], H = 'html.sy-r ';
            var ff = F[R.font] || F.song, M = H + '#Main_Content_Val';
            return [
              H + ',html.sy-r body{background:' + bg + ' !important;color:' + fg + ' !important;min-width:0 !important;margin:0 !important}',
              H + '.sy-hide{display:none !important}',
              H + ',html.sy-r *{-webkit-user-select:text !important;user-select:text !important}',
              H + '#the_content{display:block !important;float:none !important;width:auto !important;max-width:' + R.width + 'px !important;margin:0 auto !important;padding:40px 28px 90px !important;background:transparent !important;box-sizing:border-box}',
              H + '#the_content *{box-sizing:border-box}',
              H + '#conTit h1{font:700 ' + (R.size * 1.55) + 'px/1.4 ' + (R.font === 'kai' ? F.kai : F.hei) + ' !important;color:' + fg + ' !important;margin:0 0 14px !important;padding:0 !important;height:auto !important;text-autospace:ideograph-alpha ideograph-numeric;line-break:strict}',
              H + '#artInfo,' + H + '#artInfo a{font-size:13px !important;color:' + fg + ' !important;opacity:.6}',
              H + '#subhead,' + H + '.subhead{font-size:' + (R.size * 0.9) + 'px !important;line-height:1.7 !important;color:' + fg + ' !important;opacity:.78;margin:6px 0 18px !important;padding:0 0 0 12px !important;border-left:3px solid ' + ac + ' !important;background:none !important;text-autospace:ideograph-alpha ideograph-numeric}',
              H + '#the_content .content,' + H + '.textbox,' + H + '.text{width:auto !important;float:none !important;padding:0 !important;margin:0 !important;background:none !important}',
              M + ',' + M + ' *{font-family:' + ff + ' !important;font-size:' + R.size + 'px !important;line-height:' + R.leading + ' !important;color:' + fg + ' !important;background:none !important;text-autospace:ideograph-alpha ideograph-numeric;line-break:strict;word-break:normal;overflow-wrap:break-word;text-wrap:pretty;font-kerning:normal}',
              M + ' p{margin:0 0 ' + (R.indent ? '.55em' : '.95em') + ' !important;text-indent:' + (R.indent ? '2em' : '0') + ' !important;text-align:' + (R.justify ? 'justify' : 'left') + ';text-justify:inter-character}',
              M + ' p.sy-h,' + M + ' p.sy-h *{font-size:' + (R.size * 1.08) + 'px !important;font-weight:700 !important}',
              M + ' p.sy-h{text-indent:0 !important;margin:1.7em 0 .6em !important;text-align:left}',
              M + ' p.sy-by,' + M + ' p.sy-by *{font-size:' + (R.size * 0.82) + 'px !important;opacity:.62}',
              M + ' p.sy-by{text-indent:0 !important;margin:0 0 1.4em !important;text-align:left}',
              M + ' b,' + M + ' strong{font-weight:700 !important}',
              M + ' a{color:' + ac + ' !important;text-decoration:none}',
              H + '#the_content img{max-width:100% !important;height:auto !important;border-radius:6px}',
              H + '.media,' + H + '.media_pic{width:auto !important;float:none !important;margin:12px 0 !important}',
              H + '.media_pic dd{font-size:13px !important;line-height:1.6 !important;opacity:.65;color:' + fg + ' !important}',
              H + '.pip,' + H + '.pip_ad,' + H + '.bd_block,' + H + '.icon_key,' + H + '.article_topic,' + H + '.moreReport,' + H + '.content-tag,' + H + '.lanmu_textend,' + H + '#pay-layer-ad,' + H + '#pay-layer-pro-ad{display:none !important}',
              H + '#pageNext{margin:20px 0 !important}',
              H + '.idetor{font-size:13px;opacity:.55;margin-top:24px}',
              H + '#chargeWall{margin-top:18px}'
            ].join('\n');
          }
          R.set = function (o) {
            for (var k in o) { R[k] = o[k]; }
            var s = document.getElementById('sy-reader-style');
            if (s) { s.textContent = css(); }
          };
          function unapply() {
            document.documentElement.classList.remove('sy-r');
            var rs = document.querySelectorAll('.sy-root');
            for (var j = 0; j < rs.length; j++) { rs[j].classList.remove('sy-root'); }
            var hs = document.querySelectorAll('.sy-hide');
            for (var i = 0; i < hs.length; i++) { hs[i].classList.remove('sy-hide'); }
            var st = document.getElementById('sy-reader-style');
            if (st) { st.textContent = ''; }
          }
          if (isAI) {
            // AIHOT 是单页应用：站内跳转不会重新加载页面，隔一会儿看一眼当前是不是条目页
            var curArt = null;
            setInterval(function () {
              var a = document.querySelector('main article');
              if (a && a !== curArt) { curArt = a; content = a; unapply(); apply(); report(); }
              else if (!a && curArt) { curArt = null; unapply(); post({ article: false }); }
            }, 900);
          }
          if (!isArticle) { post({ article: false }); return; }
          // 去掉段首的全角空格 / 空白，标出署名行和小标题
          function normalize() {
            var m = document.getElementById('Main_Content_Val');
            if (!m) { return; }
            var ps = m.querySelectorAll('p');
            for (var i = 0; i < ps.length; i++) {
              var p = ps[i];
              if (p.getAttribute('data-sy')) { continue; }
              var w = document.createTreeWalker(p, NodeFilter.SHOW_TEXT), n;
              while ((n = w.nextNode())) {
                n.nodeValue = n.nodeValue.replace(/^[\s\u3000]+/, '');
                if (n.nodeValue.length) { break; }
              }
              var t = (p.textContent || '').trim();
              if (!t) { continue; }
              if (/^文[｜|]/.test(t)) { p.classList.add('sy-by'); }
              else if (p.children.length === 1 && /^(B|STRONG)$/.test(p.firstElementChild.tagName) && (p.firstElementChild.textContent || '').trim() === t && t.length < 40) { p.classList.add('sy-h'); }
              p.setAttribute('data-sy', '1');
            }
          }
          function apply() {
            var st = document.getElementById('sy-reader-style');
            if (!st) { st = document.createElement('style'); st.id = 'sy-reader-style'; document.head.appendChild(st); }
            st.textContent = css();
            document.documentElement.classList.add('sy-r');
            if (isAI && content) { content.classList.add('sy-root'); }
            var cur = content;
            while (cur && cur !== document.body) {
              var p = cur.parentElement;
              if (!p) { break; }
              for (var i = 0; i < p.children.length; i++) {
                var s = p.children[i];
                if (s !== cur && !/^(SCRIPT|STYLE|LINK|META)$/.test(s.tagName)) { s.classList.add('sy-hide'); }
              }
              cur = p;
            }
            if (!isAI && !isLW) { normalize(); }
          }
          function report() {
            if (isLW) {
              var bd = document.querySelector('.area6 .bd');
              var chars = bd ? (bd.innerText || '').replace(/\s/g, '').length : 0;
              var txt = (content && content.innerText) || '';
              post({ article: true, chars: chars, locked: /本文仅开放给|您还没有订阅|订阅用户/.test(txt) && chars < 1500 });
              return;
            }
            if (isAI) {
              post({ article: true, chars: ((content && content.innerText) || '').replace(/\s/g, '').length, locked: false });
              return;
            }
            normalize();
            var m = document.getElementById('Main_Content_Val');
            var cw = document.getElementById('chargeWall');
            var chars = m ? (m.innerText || '').replace(/\s/g, '').length : 0;
            var locked = !!(cw && (cw.innerText || '').replace(/\s/g, '').length > 0);
            post({ article: true, chars: chars, locked: locked });
          }
          apply();
          report();
          setTimeout(report, 1500);
          setTimeout(report, 4000);
        })();
        """#
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any] else { return }
        if let s = d["sel"] as? String { selection = s; return }
        let a = (d["article"] as? Bool) ?? false
        let l = (d["locked"] as? Bool) ?? false
        if article != a { article = a }
        if locked != l { locked = l }
    }

    // MARK: 右键菜单

    /// 精简网页自带的右键菜单：去掉刷新 / 前进后退 / 检查元素 / 新窗口 / 下载 / 朗读 / 分享，补上阅读用的几项
    fileprivate func customize(_ menu: NSMenu) {
        let drop = ["reload", "goback", "goforward", "inspect", "newwindow", "download", "speech", "share", "openframe", "openmedia"]
        menu.items.removeAll { item in
            let id = (item.identifier?.rawValue ?? "").lowercased()
            return drop.contains { id.contains($0) }
        }
        // 去掉头尾和连续的分隔线
        func tidy() {
            while let f = menu.items.first, f.isSeparatorItem { menu.removeItem(f) }
            while let l = menu.items.last, l.isSeparatorItem { menu.removeItem(l) }
            var i = 1
            while i < menu.items.count {
                if menu.items[i].isSeparatorItem && menu.items[i - 1].isSeparatorItem { menu.removeItem(at: i) } else { i += 1 }
            }
        }
        tidy()

        func add(_ title: String, _ icon: String, _ sel: Selector, at index: Int? = nil) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            if let index { menu.insertItem(it, at: index) } else { menu.addItem(it) }
            return it
        }

        let hasSel = !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasSel {
            // 选中了文字：摘录放在最前面
            _ = add("摘到便签（带出处）", "note.text.badge.plus", #selector(menuClip), at: 0)
            _ = add("复制为引用", "text.quote", #selector(menuCopyQuote), at: 1)
            menu.insertItem(.separator(), at: 2)
        } else if menu.items.isEmpty {
            // 空白处：浏览和阅读设置
            if canGoBack { _ = add("返回", "chevron.left", #selector(menuBack)) }
            _ = add("刷新", "arrow.clockwise", #selector(menuReload))
            menu.addItem(.separator())
            if article {
                _ = add("字号加大", "textformat.size.larger", #selector(menuBigger))
                _ = add("字号减小", "textformat.size.smaller", #selector(menuSmaller))
                let theme = NSMenuItem(title: "阅读外观", action: nil, keyEquivalent: "")
                theme.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
                let sub = NSMenu()
                for (k, name) in [("paper", "纸张"), ("white", "白色"), ("dark", "深色")] {
                    let it = NSMenuItem(title: name, action: #selector(menuTheme(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = k
                    it.state = self.theme == k ? .on : .off
                    sub.addItem(it)
                }
                theme.submenu = sub
                menu.addItem(theme)
                menu.addItem(.separator())
            }
            _ = add("复制本页链接", "link", #selector(menuCopyLink))
            _ = add("在浏览器中打开", "safari", #selector(menuOpenBrowser))
        }
        tidy()
    }

    @objc private func menuClip() { Task { await clipSelectionToSticky() } }
    @objc private func menuBack() { goBack() }
    @objc private func menuReload() { webView.reload() }
    @objc private func menuBigger() { size = min(size + 1, 30) }
    @objc private func menuSmaller() { size = max(size - 1, 14) }
    @objc private func menuOpenBrowser() { openInBrowser() }
    @objc private func menuTheme(_ s: NSMenuItem) { if let k = s.representedObject as? String { theme = k } }
    @objc private func menuCopyLink() {
        guard let u = webView.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
    }
    @objc private func menuCopyQuote() {
        let sel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sel.isEmpty else { return }
        var text = sel
        if let u = webView.url {
            let title = (webView.title ?? u.host ?? "原文").replacingOccurrences(of: "最新财新周刊｜", with: "")
            text += "\n——《\(title)》\(u.absoluteString)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = navigationAction.request.url else { decisionHandler(.allow); return }
        // 微信 / 应用内协议之类：交给系统，不在这里打开
        if let s = u.scheme, !["http", "https", "about", "blob", "data"].contains(s) {
            NSWorkspace.shared.open(u)
            decisionHandler(.cancel)
            return
        }
        // 链接要求新窗口：就在这个浏览器里打开
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        article = false
        locked = false
        selection = ""
        if let u = webView.url { url = u; onLogin = u.host == "u.caixin.com" }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if pendingRoot, let item = webView.backForwardList.currentItem {
            root = item
            pendingRoot = false
        }
        updateBack()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        updateBack()
        if let u = webView.url { url = u; onLogin = u.host == "u.caixin.com" }
        Task { await refreshLogin() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        updateBack()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        updateBack()
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url { webView.load(URLRequest(url: u)) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "好")
        a.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "确定")
        a.addButton(withTitle: "取消")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }
}

/// 把控制器里那一个 WKWebView 摆进 SwiftUI（切走页面再回来，打开的文章和登录状态都还在）
struct ReaderWebView: NSViewRepresentable {
    let controller: ReaderController

    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// 带自定义右键菜单的 WKWebView
final class ReaderWKWebView: WKWebView {
    weak var controller: ReaderController?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        MainActor.assumeIsolated { controller?.customize(menu) }
    }
}
