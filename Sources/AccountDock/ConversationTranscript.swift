import SwiftUI
import WebKit

/// Sandboxed local Markdown surface. No network resources, raw HTML, or application navigation.
struct ConversationTranscript: NSViewRepresentable {
    static var resourceURL: URL? { Bundle.module.url(forResource: "transcript", withExtension: "html", subdirectory: "Transcript") }
    let messages: [ConversationMessage]
    let onSelection: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "sideChat")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        if let url = Self.resourceURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onSelection = onSelection
        context.coordinator.update(view, messages: messages)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "sideChat")
        view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onSelection: (String) -> Void
        var messages: [ConversationMessage] = []
        var ready = false
        var rendered: [String] = []
        init(onSelection: @escaping (String) -> Void) { self.onSelection = onSelection }
        func update(_ view: WKWebView, messages: [ConversationMessage]) {
            self.messages = messages
            guard ready else { return }
            let keys = messages.map { $0.id + $0.text }
            guard keys != rendered else { return }
            let older = !rendered.isEmpty && keys.count > rendered.count && keys.suffix(rendered.count).elementsEqual(rendered)
            rendered = keys
            let payload = messages.map { ["id": $0.id, "role": $0.role, "text": $0.text] }
            Task { _ = try? await view.callAsyncJavaScript("window.setMessages(items, older)", arguments: ["items": payload, "older": older], in: nil, contentWorld: .page) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; update(webView, messages: messages) }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                if let url = action.request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel) }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: String],
                  let id = body["id"], messages.contains(where: { $0.id == id }),
                  let text = body["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 64_000 else { return }
            onSelection(text)
        }
    }
}
