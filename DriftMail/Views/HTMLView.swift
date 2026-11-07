import SwiftUI
import WebKit

/// Renders an HTML email in a screen-sized web view that scrolls it, with the native
/// sender header above and attachments below scrolling along (as in Apple Mail).
///
/// Sizing follows Apple Mail: a fixed-width newsletter (usually 600 px) is scaled as a
/// whole to fill the width, and anything wider than the screen is scaled down.
///
/// Security: email HTML is untrusted. JavaScript is off, nothing but the email itself may
/// load in the view (no meta refresh, frames or redirects), and tapped links only open
/// for safe schemes. Remote images can be blocked (Settings) to stop tracking pixels.
struct HTMLView: UIViewRepresentable {
    var html: String
    /// Native views that scroll with the email: the sender header above it and the
    /// attachments below it.
    var header: AnyView
    var footer: AnyView?
    /// Block http(s) loads (remote images, tracking pixels) until the user allows them.
    var blockRemoteContent = false
    /// `mailto:` links open a DriftMail compose window instead of another app.
    var onMailto: (String) -> Void = { _ in }
    /// Called with a reason if the email can't be displayed (so the text version can be shown).
    var onFailure: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onMailto: onMailto, onFailure: onFailure) }

    func makeUIView(context: Context) -> HeaderedWebView {
        let config = WKWebViewConfiguration()
        // Links and phone numbers only: address/date detection is heavy, iOS-only work
        // on the whole email, and the emails that rendered blank all had postal addresses.
        config.dataDetectorTypes = [.link, .phoneNumber]
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let script = WKUserScript(source: Self.measureScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        config.userContentController.addUserScript(script)
        config.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "size")
        if blockRemoteContent, let rules = RemoteContent.blockRules {
            config.userContentController.add(rules)
        }

        // The web view is only as big as the screen and scrolls the email itself, like
        // Apple Mail, instead of being as tall as the whole email inside another scroll
        // view: one view thousands of points tall went blank on the large inner display.
        let webView = HeaderedWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.alwaysBounceVertical = true
        // Pinch-zoom would scale the email but not the native header; the email is
        // already scaled to fit the width.
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
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

    /// Never inherit the web view's forced light mode in the native header and footer.
    private static func style(for scheme: ColorScheme) -> UIUserInterfaceStyle {
        scheme == .dark ? .dark : .light
    }

    func updateUIView(_ webView: HeaderedWebView, context: Context) {
        context.coordinator.onMailto = onMailto
        context.coordinator.onFailure = onFailure
        let appStyle = Self.style(for: context.environment.colorScheme)
        webView.setAccessories(header: header, footer: footer, style: appStyle)
        // Overscroll above and below the email shows the app's background.
        webView.underPageBackgroundColor = appStyle == .dark ? .black : .white
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        context.coordinator.start(webView, page: Self.wrap(html))
    }

    static func dismantleUIView(_ webView: HeaderedWebView, coordinator: Coordinator) {
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

    /// Remote web fonts and external stylesheets are dropped, as Gmail and Outlook do: on
    /// iOS, text waiting for a web font stays invisible, and these requests also tell
    /// senders that the email was opened.
    private static func stripRemoteStyles(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: #"@font-face\s*\{[^}]*\}"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<link\b[^>]*rel\s*=\s*["']?stylesheet[^>]*>"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"@import\s+[^;]+;"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        return text
    }

    private static func wrap(_ rawHTML: String) -> String {
        let html = stripRemoteStyles(rawHTML)
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
      var lastWidth = -1;
      function fit() {
        var root = document.getElementById('drift-root');
        if (!root) return;
        lastWidth = document.documentElement.clientWidth;
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
      // Only a width change needs a new scale. Height-only resizes happen while the email
      // bounces at its ends (bars showing and hiding); rescaling then made it jump.
      window.addEventListener('resize', function() {
        if (document.documentElement.clientWidth !== lastWidth) { schedule(); }
      });
      // Images that finish loading late can change the layout's width.
      document.addEventListener('load', function(event) {
        if (event.target && event.target.tagName === 'IMG') { schedule(); }
      }, true);
      fit();
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedHTML: String?
        var onMailto: (String) -> Void
        var onFailure: (String) -> Void
        private var page = ""
        private var reloads = 0
        private var measured = false
        private var watchdog: DispatchWorkItem?

        init(onMailto: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
            self.onMailto = onMailto
            self.onFailure = onFailure
        }

        /// Loads the email and gives it a few seconds to lay out; if it never does (the
        /// web process hung or ended), the message falls back to its text version.
        func start(_ webView: WKWebView, page: String) {
            self.page = page
            reloads = 0
            load(webView)
        }

        private func load(_ webView: WKWebView) {
            measured = false
            watchdog?.cancel()
            let check = DispatchWorkItem { [weak self] in
                guard let self, !self.measured else { return }
                self.onFailure("The email didn\u{2019}t finish displaying.")
            }
            watchdog = check
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: check)
            webView.loadHTMLString(page, baseURL: nil)
        }

        /// iOS ended the web content process (e.g. it ran out of memory): try once more.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if reloads == 0 {
                reloads += 1
                load(webView)
            } else {
                watchdog?.cancel()
                onFailure("iOS stopped the email view while displaying this message.")
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // The script reports the laid-out height: proof the email rendered.
            guard message.body is Double || message.body is Int else { return }
            measured = true
            watchdog?.cancel()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            (webView as? HeaderedWebView)?.scrollToTop()
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

/// A WKWebView whose scroll view also carries native SwiftUI views: a header above the
/// email (in the top content inset) and a footer below it (in the bottom inset).
final class HeaderedWebView: WKWebView {
    private let headerHost = UIHostingController<AnyView>(rootView: AnyView(EmptyView()))
    private let footerHost = UIHostingController<AnyView>(rootView: AnyView(EmptyView()))
    private var headerHeight: CGFloat = 0
    private var footerHeight: CGFloat = 0
    private var contentSizeObservation: NSKeyValueObservation?
    /// Once the person scrolls, the email is never moved for them again.
    private var userHasScrolled = false

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        for host in [headerHost, footerHost] {
            host.view.backgroundColor = .clear
            scrollView.addSubview(host.view)
        }
        // The footer follows the end of the email as it lays out and images load.
        contentSizeObservation = scrollView.observe(\.contentSize) { [weak self] _, _ in
            DispatchQueue.main.async { self?.setNeedsLayout() }
        }
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(userPanned))
    }

    @objc private func userPanned() {
        userHasScrolled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setAccessories(header: AnyView, footer: AnyView?, style: UIUserInterfaceStyle) {
        headerHost.rootView = header
        footerHost.rootView = footer ?? AnyView(EmptyView())
        headerHost.view.overrideUserInterfaceStyle = style
        footerHost.view.overrideUserInterfaceStyle = style
        footerHost.view.isHidden = footer == nil
        setNeedsLayout()
    }

    /// Shows the header (top of the message) unless the person already scrolled.
    func scrollToTop() {
        guard !userHasScrolled, !scrollView.isTracking, !scrollView.isDecelerating else { return }
        scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        let fitting = CGSize(width: width, height: .greatestFiniteMagnitude)
        let newHeader = ceil(headerHost.sizeThatFits(in: fitting).height)
        let newFooter = footerHost.view.isHidden ? 0 : ceil(footerHost.sizeThatFits(in: fitting).height)
        if abs(newHeader - headerHeight) > 0.5 || abs(newFooter - footerHeight) > 0.5 {
            let atTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1
            headerHeight = newHeader
            footerHeight = newFooter
            scrollView.contentInset = UIEdgeInsets(top: headerHeight, left: 0, bottom: footerHeight, right: 0)
            scrollView.verticalScrollIndicatorInsets = scrollView.contentInset
            if atTop { scrollToTop() }
        }
        headerHost.view.frame = CGRect(x: 0, y: -headerHeight, width: width, height: headerHeight)
        footerHost.view.frame = CGRect(x: 0, y: scrollView.contentSize.height, width: width, height: footerHeight)
    }
}
