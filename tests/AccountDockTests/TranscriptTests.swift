import XCTest
import WebKit
@testable import AccountDock

final class TranscriptTests: XCTestCase {
    @MainActor func testQuotedKoreanEmphasisPreservesLiteralCodeAndMath() async throws {
        let url = try XCTUnwrap(ConversationTranscript.resourceURL)
        let view = WKWebView(frame: CGRect(x:0,y:0,width:700,height:480))
        view.loadFileURL(url, allowingReadAccessTo:url.deletingLastPathComponent())
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof window.setMessages==='function'")) as? Bool == true { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        let examples: [(String,Int)] = [
            ("**“모두 더하라”**는 기호이고 **ITE**, **ATE**라고 부릅니다.",3),
            ("**\"평균\"**이라고 **‘차이’**를 **중요!**입니다.",3),
            ("그는 \"**강조**라고\" 말했다.",1),
            ("**앞** 그리고 **“뒤”**는",2),
            ("**“*중첩*”**도",1),
            ("`**“코드”**는`\n\n```text\n**“그대로”**는\n```",0),
            (#"\*\*“문자”\*\*는"#,0),
            ("**“닫히지 않음”는",0),
            ("**\"English\"**suffix",0),
            (#"\(\text{**“수식”**는}\)"#,0)
        ]
        for (source,count) in examples {
            _ = try await view.callAsyncJavaScript("window.setMessages(items,false)",arguments:["items":[["id":"quote","role":"agentMessage","text":source]]],in:nil,contentWorld:.page)
            let actual = try await view.evaluateJavaScript("document.querySelectorAll('strong').length") as? Int
            XCTAssertEqual(actual,count,source)
        }
    }

    @MainActor func testLocalMathRenderingAndFallback() async throws {
        let url = try XCTUnwrap(ConversationTranscript.resourceURL)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 640))
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof window.setMessages==='function'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let sample = #"""
        세 사람의 평균 효과는 다음과 같습니다.

        \[
        \frac{10+5+0}{3}=5
        \]

        즉, 교육이 점수를 평균 **5점** 높였습니다.

        인라인 \(x_i^2 + \alpha\) 및 $E=mc^2$.

        $$
        \begin{aligned}
        a &= b+c \\
        \sigma &= \sqrt{\frac{1}{n}\sum_{i=1}^{n}(x_i-\mu)^2}
        \end{aligned}
        $$

        | 항목 | 값 |
        | --- | --- |
        | 평균 | $\bar{x}=5$ |

        `\(code\)`와 `$literal$`는 코드입니다. 가격은 $20와 $30입니다.

        ```tex
        \[not rendered\]
        ```
        \(\notARealCommand{<img src=x onerror=alert(1)>}\)
        \(\href{javascript:alert(1)}{x}\)
        \(\includegraphics{https://example.com/track}\)
        """#
        _ = try await view.callAsyncJavaScript("window.setMessages(items,false); await document.fonts.ready; window.scrollTo(0,0)", arguments: ["items": [["id":"math","role":"agentMessage","text":sample]]], in:nil, contentWorld:.page)
        let result = try await view.evaluateJavaScript("({math:document.querySelectorAll('.katex').length,display:document.querySelectorAll('.katex-display').length,fallback:document.querySelectorAll('.math-fallback').length,code:document.querySelector('pre code').textContent,inline:document.querySelector('code').textContent,table:document.querySelectorAll('table .katex').length,safe:!document.querySelector('img,a[href^=\"javascript:\"]'),fonts:[...document.fonts].filter(f=>f.family.startsWith('KaTeX')&&f.status==='loaded').length,currency:document.body.textContent.includes('$20와 $30')})") as? [String:Any]
        XCTAssertGreaterThanOrEqual(result?["math"] as? Int ?? 0, 5)
        XCTAssertEqual(result?["display"] as? Int, 2)
        XCTAssertGreaterThanOrEqual(result?["fallback"] as? Int ?? 0, 1)
        XCTAssertEqual(result?["code"] as? String, "\\[not rendered\\]\n")
        XCTAssertEqual(result?["inline"] as? String, "\\(code\\)")
        XCTAssertEqual(result?["table"] as? Int, 1)
        XCTAssertEqual(result?["safe"] as? Bool, true)
        XCTAssertEqual(result?["currency"] as? Bool, true)
        XCTAssertGreaterThan(result?["fonts"] as? Int ?? 0, 0)
        if let path = ProcessInfo.processInfo.environment["ACCOUNT_DOCK_MATH_SNAPSHOT"] {
            let image = try await view.takeSnapshot(configuration:nil)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation)))
            try bitmap.representation(using:.png,properties:[:])?.write(to: URL(fileURLWithPath:path))
        }
    }

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
        let long = String(repeating: "긴 대화 문단입니다.\n\n", count: 100)
        _ = try await view.callAsyncJavaScript("window.setMessages(items,false)", arguments: ["items": [["id": "long", "role": "agentMessage", "text": long]]], in: nil, contentWorld: .page)
        let initialBottom = try await view.evaluateJavaScript("scrollY > 0 && document.documentElement.scrollHeight-innerHeight-scrollY < 2") as? Bool
        XCTAssertEqual(initialBottom, true)
        _ = try await view.evaluateJavaScript("scrollTo(0,0);dispatchEvent(new Event('scroll'));true")
        let buttonVisible = try await view.evaluateJavaScript("!document.getElementById('latest').hidden") as? Bool
        XCTAssertEqual(buttonVisible, true)
        _ = try await view.evaluateJavaScript("document.getElementById('latest').click();true")
        let returnedToBottom = try await view.evaluateJavaScript("document.documentElement.scrollHeight-innerHeight-scrollY < 2") as? Bool
        XCTAssertEqual(returnedToBottom, true)
    }
}
