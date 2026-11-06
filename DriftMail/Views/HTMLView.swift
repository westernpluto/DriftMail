import SwiftUI
import WebKit

/// Renders an HTML email at its natural height so it scrolls with the rest of the message.
///
/// Sizing follows Apple Mail: a fixed-width newsletter (usually 600 px) is scaled as a
/// whole to fill the width, and anything wider than the screen is scaled down.
///
/// Security: email HTML is untrusted. JavaScript is off, nothing but the email itself may
/// load in the view (no meta refresh, frames or redirects), and tapped links only open
/// for safe schemes. Remote images can be blocked (Settings) to stop tracking pixels.
struct HTMLView: UIViewRepresentable {
    var html: String
    @Binding var height: CGFloat
    /// Block http(s) loads (remote images, tracking pixels) until the user allows them.
    var blockRemoteContent = false
    /// `mailto:` links open a DriftMail compose window instead of another app.
    var onMailto: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(height: $height, onMailto: onMailto) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = [.link, .phoneNumber, .address, .calendarEvent]
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let script = WKUserScript(source: Self.measureScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        config.userContentController.addUserScript(script)
        config.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "size")
        if blockRemoteContent, let rules = RemoteContent.blockRules {
            config.userContentController.add(rules)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        // Render email as designed for light mode, like Apple Mail does here. In Dark Mode
        // the web view otherwise reports `prefers-color-scheme: dark`, and emails with
        // their own dark styles could turn into dark text on a black, empty-looking card.
        webView.overrideUserInterfaceStyle = .light
        // White while loading, never a transparent (black, "blank") box.
        webView.isOpaque = true
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onMailto = onMailto
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(Self.wrap(html), baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "size", contentWorld: .defaultClient)
    }

    /// Starts WebKit's processes at launch so the first email doesn't wait for them,
    /// and compiles the remote-content blocking rules.
    @MainActor
    static func prewarm() {
        guard warmWebView == nil else { return }
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        warmWebView = webView
        Task { await RemoteContent.prepare() }
    }

    @MainActor private static var warmWebView: WKWebView?

    /// True if the email loads anything from the network (images, backgrounds).
    static func hasRemoteContent(_ html: String) -> Bool {
        html.range(of: #"(src|background)\s*=\s*["']?\s*https?:|url\(\s*["']?\s*https?:"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func wrap(_ html: String) -> String {
        // Newsletters (table layouts) go edge to edge, as in Apple Mail; simple text
        // emails get normal reading margins.
        let isLayout = html.range(of: "<table", options: .caseInsensitive) != nil
        let padding = isLayout ? "0" : "16px"
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light">
        <meta name="referrer" content="no-referrer">
        <style>
          html, body { margin: 0; padding: 0; background: #ffffff; }
          body { font: -apple-system-body; color: #1c1c1e; word-wrap: break-word; overflow-wrap: anywhere; padding: \(padding); }
          img { max-width: 100%; }
          pre { white-space: pre-wrap; }
          a { color: #3d73fa; }
          blockquote { margin-left: 0; padding-left: 12px; border-left: 3px solid #d1d1d6; color: #636366; }
        </style></head><body><div id="drift-root" data-layout="\(isLayout ? "1" : "0")">\(html)</div></body></html>
        """
    }

    /// Scales the email to the width (down if too wide; fixed-width newsletters also up),
    /// keeps capped images in proportion, then reports the height.
    /// User scripts run even with page JavaScript disabled.
    private static let measureScript = """
    (function() {
      var queued = false;
      function fit() {
        var root = document.getElementById('drift-root');
        if (!root) return;
        root.style.zoom = 1;
        var style = getComputedStyle(document.body);
        var available = document.documentElement.clientWidth
          - parseFloat(style.paddingLeft || 0) - parseFloat(style.paddingRight || 0);
        var zoom = 1;
        if (available > 0) {
          var needed = root.scrollWidth;
          if (needed > available + 1) {
            zoom = available / needed;
          } else if (root.getAttribute('data-layout') === '1') {
            var design = 0;
            var tables = root.getElementsByTagName('table');
            for (var i = 0; i < tables.length; i++) {
              var w = tables[i].getBoundingClientRect().width;
              if (w >= 400 && w < available - 8 && w > design) { design = w; }
            }
            if (design > 0) { zoom = Math.min(available / design, 1.6); }
          }
        }
        // An image narrowed by max-width keeps its proportions instead of its fixed height.
        var images = root.getElementsByTagName('img');
        for (var j = 0; j < images.length; j++) {
          var img = images[j];
          var declared = parseFloat(img.getAttribute('width') || '0');
          if (img.hasAttribute('height') && declared > 0 && img.getBoundingClientRect().width < declared - 1) {
            img.style.height = 'auto';
          }
        }
        root.style.zoom = Math.max(0.25, zoom);
        var body = document.body;
        var height = Math.max(body.scrollHeight, body.offsetHeight, Math.ceil(body.getBoundingClientRect().height));
        // Layouts built with absolute positioning don't add to the body's height; use
        // where the content actually ends so such an email never collapses to nothing.
        var all = root.getElementsByTagName('*');
        var count = Math.min(all.length, 4000);
        for (var k = 0; k < count; k++) {
          var rect = all[k].getBoundingClientRect();
          if (rect.height > 0 && rect.bottom + window.scrollY > height) { height = Math.ceil(rect.bottom + window.scrollY); }
        }
        window.webkit.messageHandlers.size.postMessage(height);
      }
      function schedule() {
        if (queued) { return; }
        queued = true;
        requestAnimationFrame(function() { queued = false; fit(); });
      }
      window.addEventListener('load', schedule);
      window.addEventListener('resize', schedule);
      if (window.ResizeObserver) { new ResizeObserver(schedule).observe(document.body); }
      fit();
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        var loadedHTML: String?
        var onMailto: (String) -> Void

        init(height: Binding<CGFloat>, onMailto: @escaping (String) -> Void) {
            self.height = height
            self.onMailto = onMailto
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double ?? (message.body as? Int).map(Double.init) else { return }
            // Never collapse to (almost) nothing, which looked like a blank black message.
            let newHeight = max(CGFloat(value), 60)
            if abs(newHeight - height.wrappedValue) > 1 {
                DispatchQueue.main.async { self.height.wrappedValue = newHeight }
            }
        }

        /// Schemes a tapped link may open outside the app.
        private static let externalSchemes: Set<String> = ["http", "https", "tel", "sms", "facetime", "facetime-audio", "maps"]

        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            // The email itself (loadHTMLString with no base URL) is the only page allowed.
            if navigationAction.navigationType == .other, url?.absoluteString == "about:blank",
               navigationAction.targetFrame?.isMainFrame ?? false {
                return .allow
            }
            if navigationAction.navigationType == .linkActivated, let url {
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme == "mailto" {
                    let address = url.absoluteString.dropFirst("mailto:".count)
                        .split(separator: "?").first.map(String.init)?.removingPercentEncoding ?? ""
                    onMailto(address)
                } else if Self.externalSchemes.contains(scheme) {
                    await UIApplication.shared.open(url)
                }
            }
            // Everything else (meta refresh, frames, redirects, unknown schemes) is refused.
            return .cancel
        }
    }
}

/// Content blocking for remote images (privacy: tracking pixels reveal when and where
/// an email was opened). Compiled once; applied per message view.
@MainActor
enum RemoteContent {
    static let blockKey = "blockRemoteImages"
    private(set) static var blockRules: WKContentRuleList?

    static var isBlocking: Bool { UserDefaults.standard.bool(forKey: blockKey) }

    static func prepare() async {
        guard blockRules == nil, let store = WKContentRuleListStore.default() else { return }
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        blockRules = try? await store.compileContentRuleList(forIdentifier: "DriftMailBlockRemote",
                                                              encodedContentRuleList: rules)
    }
}
