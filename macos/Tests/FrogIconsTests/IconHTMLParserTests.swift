import Foundation
import XCTest
@testable import FrogIcons

final class IconHTMLParserTests: XCTestCase {
    func testDeclarationsHandleCaseAttributeOrderAndQuoting() {
        let html = """
        <LINK sizes='32x32' HREF='/small.png' REL=icon>
        <link href="touch.png" sizes="180x180" rel="APPLE-TOUCH-ICON">
        <link type="image/x-icon" rel='shortcut icon' href=../favicon.ico>
        <link href='not-an-icon.css' rel=stylesheet>
        """
        let result = IconHTMLParser.candidates(in: html, finalPageURL: URL(string: "https://example.com/path/page")!)
        XCTAssertEqual(result.map(\.url.absoluteString), ["https://example.com/path/touch.png", "https://example.com/small.png", "https://example.com/favicon.ico"])
    }

    func testBaseUsesFinalRedirectedPageAndFirstValidBase() {
        let html = """
        <base href='javascript:alert(1)'>
        <link rel='icon' href='icons/icon.png?x=1&amp;y=&#50;'>
        <base href='../static/'>
        <base href='https://wrong.example/'>
        """
        let result = IconHTMLParser.candidates(in: html, finalPageURL: URL(string: "https://redirect.example/landing/index.html")!)
        XCTAssertEqual(result.first?.url.absoluteString, "https://redirect.example/static/icons/icon.png?x=1&y=2")
    }

    func testRejectsUnsafeSchemesAndIgnoresCommentAndScriptDeclarations() {
        let html = """
        <!-- <link rel=icon href='https://invalid.example/comment.png'> -->
        <script>const bad = '<link rel=icon href="/script.png">';</script>
        <style>x: '<link rel=icon href="/style.png">';</style>
        <link rel=icon href='file:///tmp/icon.png'>
        <link rel=icon href='data:image/png;base64,AAAA'>
        <link rel=icon href='//cdn.example/good.png'>
        <link rel='shortcut icon' href='//cdn.example/good.png'>
        """
        let result = IconHTMLParser.candidates(in: html, finalPageURL: URL(string: "https://example.com/")!)
        XCTAssertEqual(result.map(\.url.absoluteString), ["https://cdn.example/good.png"])
    }

    func testRootFallbackDiscardsPagePathQueryAndFragment() {
        XCTAssertEqual(IconURL.rootIcon(for: URL(string: "https://example.com:8443/some/page?q=1#here")!)?.absoluteString,
                       "https://example.com:8443/favicon.ico")
        XCTAssertNil(IconURL.valid("ftp://example.com/icon.png"))
        XCTAssertNil(IconURL.valid("https://user:password@example.com/"))
    }
}
