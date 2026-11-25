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
    @Published var size: Double {
        didSet { UserDefaults.standard.set(size, forKey: "reader.size"); push() }
    }
    @Published var theme: String {
        didSet { UserDefaults.standard.set(theme, forKey: "reader.theme"); push() }
    }

    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    override init() {
        let d = UserDefaults.standard.double(forKey: "reader.size")
        size = d >= 14 ? d : 19
        theme = UserDefaults.standard.string(forKey: "reader.theme") ?? "paper"
        let uc = WKUserContentController()
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.userContentController = uc
        ucc = uc
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.customUserAgent = Self.ua
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        ucc.add(self, name: "reader")
        installScript()
    }

    // MARK: 操作

    func open(_ u: URL) {
        url = u
        webView.load(URLRequest(url: u))
    }

    /// 去财新登录页（登录完会回到 `back`）
    func openLogin(back: URL? = nil) {
        let target = back ?? webView.url ?? URL(string: "https://weekly.caixin.com/")!
        let enc = target.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        if let u = URL(string: "https://u.caixin.com/web/login?url=" + enc) { open(u) }
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
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
            let title = (webView.title ?? "财新周刊").replacingOccurrences(of: "最新财新周刊｜", with: "")
            text += "\n\n[\(title)](\(u.absoluteString))"
        }
        StickyController.shared.create(text: text)
    }

    // MARK: 阅读样式

    private func installScript() {
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: Self.script(size: size, theme: theme), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    /// 字号 / 外观变了：下次打开的页面用新值，当前页立刻更新
    private func push() {
        installScript()
        webView.evaluateJavaScript("window.__syReader && window.__syReader.set(\(size), '\(theme)')", completionHandler: nil)
    }

    private static func script(size: Double, theme: String) -> String {
        #"""
        (function () {
          if (window.__syReader) { return; }
          var R = window.__syReader = { size: \#(size), theme: '\#(theme)' };
          var T = { paper: ['#f4eee0', '#2c2a24', '#8a5a14'], white: ['#ffffff', '#1d1d1f', '#a8560a'], dark: ['#1b1b1d', '#d6d2c9', '#e9a84c'] };
          var content = document.getElementById('the_content');
          var isArticle = /^\/\d{4}-\d{2}-\d{2}\/\d+\.html/.test(location.pathname) && !!content;
          function post(o) {
            try { window.webkit.messageHandlers.reader.postMessage(o); } catch (e) {}
          }
          function css() {
            var c = T[R.theme] || T.paper, bg = c[0], fg = c[1], ac = c[2], H = 'html.sy-r ';
            return [
              H + ',html.sy-r body{background:' + bg + ' !important;color:' + fg + ' !important;min-width:0 !important;margin:0 !important}',
              H + '.sy-hide{display:none !important}',
              H + '#the_content{display:block !important;float:none !important;width:auto !important;max-width:680px !important;margin:0 auto !important;padding:40px 28px 90px !important;background:transparent !important;box-sizing:border-box}',
              H + '#the_content *{box-sizing:border-box}',
              H + '#conTit h1{font:700 ' + (R.size * 1.55) + 'px/1.4 "PingFang SC","Songti SC",serif !important;color:' + fg + ' !important;margin:0 0 14px !important;padding:0 !important;height:auto !important}',
              H + '#artInfo,' + H + '#artInfo a{font-size:13px !important;color:' + fg + ' !important;opacity:.6}',
              H + '#subhead,' + H + '.subhead{font-size:' + (R.size * 0.9) + 'px !important;line-height:1.7 !important;color:' + fg + ' !important;opacity:.78;margin:6px 0 18px !important;padding:0 0 0 12px !important;border-left:3px solid ' + ac + ' !important;background:none !important}',
              H + '#the_content .content,' + H + '.textbox,' + H + '.text{width:auto !important;float:none !important;padding:0 !important;margin:0 !important;background:none !important}',
              H + '#Main_Content_Val,' + H + '#Main_Content_Val *{font-family:"Songti SC","Source Han Serif SC","Noto Serif CJK SC",serif !important;font-size:' + R.size + 'px !important;line-height:1.95 !important;color:' + fg + ' !important;background:none !important}',
              H + '#Main_Content_Val p{margin:0 0 .9em !important;text-align:justify}',
              H + '#Main_Content_Val b,' + H + '#Main_Content_Val strong{font-weight:700 !important}',
              H + '#Main_Content_Val a{color:' + ac + ' !important;text-decoration:none}',
              H + '#the_content img{max-width:100% !important;height:auto !important;border-radius:6px}',
              H + '.media,' + H + '.media_pic{width:auto !important;float:none !important;margin:12px 0 !important}',
              H + '.media_pic dd{font-size:13px !important;line-height:1.6 !important;opacity:.65;color:' + fg + ' !important}',
              H + '.pip,' + H + '.pip_ad,' + H + '.bd_block,' + H + '.icon_key,' + H + '.article_topic,' + H + '.moreReport,' + H + '.content-tag,' + H + '.lanmu_textend,' + H + '#pay-layer-ad,' + H + '#pay-layer-pro-ad{display:none !important}',
              H + '#pageNext{margin:20px 0 !important}',
              H + '.idetor{font-size:13px;opacity:.55;margin-top:24px}',
              H + '#chargeWall{margin-top:18px}'
            ].join('\n');
          }
          R.set = function (size, theme) {
            R.size = size; R.theme = theme;
            var s = document.getElementById('sy-reader-style');
            if (s) { s.textContent = css(); }
          };
          if (!isArticle) { post({ article: false }); return; }
          function apply() {
            var st = document.getElementById('sy-reader-style');
            if (!st) { st = document.createElement('style'); st.id = 'sy-reader-style'; document.head.appendChild(st); }
            st.textContent = css();
            document.documentElement.classList.add('sy-r');
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
          }
          function report() {
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
        let a = (d["article"] as? Bool) ?? false
        let l = (d["locked"] as? Bool) ?? false
        if article != a { article = a }
        if locked != l { locked = l }
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
        if let u = webView.url { url = u; onLogin = u.host == "u.caixin.com" }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        canGoBack = webView.canGoBack
        if let u = webView.url { url = u; onLogin = u.host == "u.caixin.com" }
        Task { await refreshLogin() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        canGoBack = webView.canGoBack
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        canGoBack = webView.canGoBack
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
