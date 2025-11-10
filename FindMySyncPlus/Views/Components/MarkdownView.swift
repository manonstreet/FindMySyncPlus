import SwiftUI
import Ink
import WebKit
import AppKit

struct MarkdownView: NSViewRepresentable {
    let markdown: String

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        // JS → native bridge for external links
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "externalLink",
                  let href = message.body as? String,
                  let url = URL(string: href) else { return }
            NSWorkspace.shared.open(url)
        }

        // Handle target="_blank" / window.open
        @objc func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        // Inject a tiny script that hijacks anchor clicks and posts them to native. Links would not open in a browser without this hack
        let js = """
        document.addEventListener('click', function(e) {
          var a = e.target.closest('a');
          if (!a) return;
          var href = a.getAttribute('href') || '';
          // Ignore in-document anchors
          if (href.startsWith('#')) return;
          var externalSchemes = /^(https?:)/i;
          // External http(s) → send to native and block in-webview navigation
          if (externalSchemes.test(href)) {
            e.preventDefault();
            window.webkit.messageHandlers.externalLink.postMessage(href);
          }
        }, true);
        """

        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "externalLink")
        userContent.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let config = WKWebViewConfiguration()
        config.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // blend with sheet
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let html = MarkdownParser().html(from: markdown)
        let styledHTML = """
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            :root {
                color-scheme: light dark;
                --link-color: #007aff;
            }
            body {
                font-family: -apple-system, sans-serif;
                font-size: 1em;
                line-height: 1.6;
                margin: 2em;
            }
            a {
                color: var(--link-color);
                text-decoration: none;
            }
            a:hover {
                text-decoration: underline;
            }
            code {
                font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                background: rgba(127,127,127,0.12);
                padding: 0.2em 0.4em;
                border-radius: 6px;
            }
            pre code {
                display: block;
                padding: 10px 12px;
                white-space: pre;
                border: 1px solid rgba(127,127,127,0.25);
                border-radius: 8px;
            }
        </style>
        \(html)
        """
        nsView.loadHTMLString(styledHTML, baseURL: nil)
    }
}
