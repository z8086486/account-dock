import XCTest
import WebKit
@testable import AccountDock

final class TranscriptTests: XCTestCase {
    @MainActor func testMarkdownAndInertContent() async throws {
        let url = try XCTUnwrap(ConversationTranscript.resourceURL)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 600))
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        var ready = false
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof window.setMessages === 'function'")) as? Bool == true { ready = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(ready)
        guard ready else { return }
        let sample = """
        ## 제목
        **강조**와 [링크](https://example.com).

        | 항목 | 값 |
        | --- | --- |
        | 한국어 | 123 |

        ```swift
        let x = "<script>"
        ```
        - 목록
        - 두 번째

        <script>window.pwned = true</script>
        <img src="https://example.com/tracker" onerror="window.pwned=true">
        [위험](javascript:alert(1))
        """
        _ = try await view.callAsyncJavaScript("window.setMessages(items,false)", arguments: ["items": [["id": "fixture", "role": "agentMessage", "text": sample]]], in: nil, contentWorld: .page)
        let result = try await view.evaluateJavaScript("({table:document.querySelectorAll('table').length,code:document.querySelectorAll('pre code').length,list:document.querySelectorAll('li').length,bold:document.querySelectorAll('strong').length,images:document.querySelectorAll('img').length,safe:!window.pwned && !document.querySelector('a[href^=\"javascript:\"]')})") as? [String: Any]
        XCTAssertEqual(result?["table"] as? Int, 1)
        XCTAssertEqual(result?["code"] as? Int, 1)
        XCTAssertEqual(result?["list"] as? Int, 2)
        XCTAssertEqual(result?["bold"] as? Int, 1)
        XCTAssertEqual(result?["images"] as? Int, 0)
        XCTAssertEqual(result?["safe"] as? Bool, true)
        _ = try await view.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('strong'));getSelection().addRange(r);document.dispatchEvent(new MouseEvent('mouseup'));true")
        let hidden = try await view.evaluateJavaScript("document.getElementById('ask').hidden") as? Bool
        XCTAssertEqual(hidden, false)
        if let path = ProcessInfo.processInfo.environment["ACCOUNT_DOCK_TRANSCRIPT_SNAPSHOT"] {
            let image = try await view.takeSnapshot(configuration: nil)
            if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
