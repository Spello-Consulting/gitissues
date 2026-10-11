//
//  MarkdownRenderView.swift
//  GitIssues
//
//  Created by Claude Code
//

import SwiftUI
import WebKit

/// A view that renders markdown content using GitHub's markdown API
struct MarkdownRenderView: View {
    let markdown: String
    let apiService: GitHubAPIService

    @Environment(\.colorScheme) private var colorScheme
    @State private var rawHTML: String?
    @State private var isLoading = true
    @State private var error: String?
    @State private var contentHeight: CGFloat = 100

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                Text("Failed to render markdown: \(error)")
                    .foregroundColor(.secondary)
                    .padding()
            } else if let html = rawHTML {
                MarkdownWebView(html: wrapHTML(html, isDarkMode: colorScheme == .dark), contentHeight: $contentHeight)
                    .frame(height: contentHeight)
            }
        }
        .task {
            await loadMarkdown()
        }
    }

    private func loadMarkdown() async {
        guard !markdown.isEmpty else {
            rawHTML = ""
            isLoading = false
            return
        }

        do {
            rawHTML = try await apiService.renderMarkdown(markdown)
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    /// Wraps the GitHub-rendered HTML with styling
    private func wrapHTML(_ html: String, isDarkMode: Bool) -> String {
        let darkClass = isDarkMode ? "dark" : ""
        return """
        <!DOCTYPE html>
        <html class="\(darkClass)">
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                html {
                    /* The host SwiftUI view sizes the web view to its full content height, so the
                       page itself must never scroll vertically. */
                    overflow-y: hidden;
                }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
                    font-size: 14px;
                    line-height: 1.5;
                    color: #24292e;
                    padding: 0;
                    margin: 0;
                    /* Establish a block formatting context so the first/last child's margins stay
                       inside <body> and are included in the measured content height. */
                    display: flow-root;
                }
                html.dark body {
                    color: #c9d1d9;
                    background: #0d1117;
                }
                html.dark a { color: #58a6ff; }
                html.dark code, html.dark pre {
                    background-color: rgba(110, 118, 129, 0.4);
                    color: #c9d1d9;
                }
                html.dark pre {
                    background-color: #161b22;
                }
                html.dark blockquote {
                    border-left-color: #55606a;
                    color: #a8b3bf;
                }
                html.dark h1, html.dark h2 { border-bottom-color: #21262d; }
                html.dark hr { background-color: #21262d; }
                html.dark table th, html.dark table td {
                    border-color: #30363d !important;
                }
                html.dark table tr {
                    background-color: #0d1117 !important;
                    border-top-color: #30363d !important;
                }
                html.dark table th {
                    background-color: #161b22 !important;
                }
                html.dark table tr:nth-child(2n) {
                    background-color: #161b22 !important;
                }
                h1, h2, h3, h4, h5, h6 {
                    margin-top: 24px;
                    margin-bottom: 16px;
                    font-weight: 600;
                    line-height: 1.25;
                }
                h1 { font-size: 2em; border-bottom: 1px solid #e1e4e8; padding-bottom: 0.3em; }
                h2 { font-size: 1.5em; border-bottom: 1px solid #e1e4e8; padding-bottom: 0.3em; }
                h3 { font-size: 1.25em; }
                h4 { font-size: 1em; }
                h5 { font-size: 0.875em; }
                h6 { font-size: 0.85em; color: #6a737d; }
                p { margin-top: 0; margin-bottom: 16px; }
                code {
                    padding: 0.2em 0.4em;
                    margin: 0;
                    font-size: 85%;
                    background-color: rgba(27, 31, 35, 0.05);
                    border-radius: 3px;
                    font-family: "SF Mono", Monaco, Consolas, monospace;
                }
                pre {
                    padding: 16px;
                    overflow: auto;
                    font-size: 85%;
                    line-height: 1.45;
                    background-color: #f6f8fa;
                    border-radius: 6px;
                    font-family: "SF Mono", Monaco, Consolas, monospace;
                }
                pre code {
                    display: inline;
                    padding: 0;
                    margin: 0;
                    overflow: visible;
                    line-height: inherit;
                    background-color: transparent;
                    border: 0;
                }
                blockquote {
                    padding: 0 1em;
                    color: #6a737d;
                    border-left: 0.25em solid #dfe2e5;
                    margin: 0 0 16px 0;
                }
                ul {
                    list-style-type: disc;
                    padding-left: 2em;
                    margin-top: 0;
                    margin-bottom: 16px;
                }
                ol {
                    list-style-type: decimal;
                    padding-left: 2em;
                    margin-top: 0;
                    margin-bottom: 16px;
                }
                li + li { margin-top: 0.25em; }
                img {
                    max-width: 100%;
                    height: auto;
                    border-radius: 6px;
                }
                table {
                    border-spacing: 0;
                    border-collapse: collapse;
                    margin-bottom: 16px;
                }
                table th, table td {
                    padding: 6px 13px;
                    border: 1px solid #d0d7de;
                }
                table th {
                    font-weight: 600;
                    background-color: #f6f8fa;
                }
                table tr {
                    background-color: #ffffff;
                    border-top: 1px solid #d0d7de;
                }
                table tr:nth-child(2n) {
                    background-color: #f6f8fa;
                }
                a {
                    color: #0969da;
                    text-decoration: none;
                }
                a:hover {
                    text-decoration: underline;
                }
                hr {
                    height: 0.25em;
                    padding: 0;
                    margin: 24px 0;
                    background-color: #e1e4e8;
                    border: 0;
                }
                input[type="checkbox"] {
                    margin: 0 0.5em 0 0;
                }
            </style>
        </head>
        <body>
            \(html)
        </body>
        </html>
        """
    }
}

/// `WKWebView` that hands vertical scroll-wheel / trackpad events to the enclosing scroll view.
///
/// The web view is sized to its full content height, so it never has anything of its own to scroll
/// vertically. Without this, the web view swallows wheel events while the pointer is over it and
/// the surrounding detail panel stops scrolling. Horizontal gestures stay with the web view so wide
/// tables and code blocks can still be panned.
final class PassthroughScrollWebView: WKWebView {
    /// Whether the in-flight scroll gesture is being forwarded to the parent. Decided once at the
    /// start of each gesture so a gesture (and its momentum) is never split between two views.
    private var forwardsToParent = true

    override func scrollWheel(with event: NSEvent) {
        let startsGesture = event.phase.contains(.began)
        let isDiscreteWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
        if startsGesture || isDiscreteWheel {
            forwardsToParent = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        }

        if forwardsToParent, let next = nextResponder {
            next.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// WKWebView wrapper for displaying HTML with auto-height
struct MarkdownWebView: NSViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat

    /// Name of the script message handler the page uses to report its content height.
    private static let heightMessageName = "contentHeight"

    /// Reports the rendered height of `<body>` whenever it changes (initial layout, images
    /// finishing loading, the panel being resized and the text re-wrapping, ...).
    private static let heightScript = """
    (function () {
        var last = -1;
        function report() {
            var h = Math.ceil(document.body.getBoundingClientRect().height);
            if (h !== last) {
                last = h;
                window.webkit.messageHandlers.\(heightMessageName).postMessage(h);
            }
        }
        new ResizeObserver(report).observe(document.body);
        window.addEventListener('load', report);
        report();
    })();
    """

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userScript = WKUserScript(
            source: Self.heightScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(context.coordinator, name: Self.heightMessageName)

        let webView = PassthroughScrollWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // Transparent background

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.contentHeight = $contentHeight
        // Only reload when the HTML actually changed; reloading on every SwiftUI update would
        // flicker and reset the height measurement.
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: heightMessageName)
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        var contentHeight: Binding<CGFloat>
        var loadedHTML: String?

        init(contentHeight: Binding<CGFloat>) {
            self.contentHeight = contentHeight
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let height = (message.body as? NSNumber).map({ CGFloat(truncating: $0) }) else { return }
            let newHeight = max(height, 40)
            if abs(contentHeight.wrappedValue - newHeight) >= 0.5 {
                contentHeight.wrappedValue = newHeight
            }
        }
    }
}
