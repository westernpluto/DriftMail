import SwiftUI
import WebKit

/// Renders an HTML email at its natural height so it scrolls with the rest of the message.
/// Wide newsletters are scaled down to fit whatever width the current pose gives us.
struct HTMLView: UIViewRepresentable {
    var html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = [.link, .phoneNumber, .address, .calendarEvent]
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let script = WKUserScript(source: Self.measureScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        config.userContentController.addUserScript(script)
        config.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "size")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(Self.wrap(html), baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "size", contentWorld: .defaultClient)
    }

    private static func wrap(_ html: String) -> String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light">
        <style>
          html, body { margin: 0; padding: 0; background: #ffffff; }
          body { font: -apple-system-body; color: #1c1c1e; word-wrap: break-word; overflow-wrap: anywhere; padding: 14px; }
          img { max-width: 100%; height: auto; }
          pre { white-space: pre-wrap; }
          a { color: #3d73fa; }
          blockquote { margin-left: 0; padding-left: 12px; border-left: 3px solid #d1d1d6; color: #636366; }
        </style></head><body><div id="drift-root">\(html)</div></body></html>
        """
    }

    /// Scales oversized content to fit, then reports the height.
    /// User scripts run even with page JavaScript disabled.
    private static let measureScript = """
    (function() {
      function fit() {
        var root = document.getElementById('drift-root');
        if (!root) return;
        root.style.zoom = 1;
        var available = document.documentElement.clientWidth - 28;
        var needed = root.scrollWidth;
        if (needed > available && available > 0) { root.style.zoom = available / needed; }
        window.webkit.messageHandlers.size.postMessage(document.documentElement.scrollHeight);
      }
      window.addEventListener('load', fit);
      window.addEventListener('resize', fit);
      if (window.ResizeObserver) { new ResizeObserver(fit).observe(document.body); }
      fit();
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        var loadedHTML: String?

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double ?? (message.body as? Int).map(Double.init) else { return }
            let newHeight = CGFloat(value)
            if abs(newHeight - height.wrappedValue) > 1 {
                DispatchQueue.main.async { self.height.wrappedValue = newHeight }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}
