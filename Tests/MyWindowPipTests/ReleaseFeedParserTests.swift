import Foundation
import XCTest
@testable import my_window_pip

/// 检查更新改走 GitHub 网页通道后的回归测试。
/// 背景：api.github.com 未认证请求只有 60 次/小时/IP，超限返回 403（不是 429），
/// 用户会看到莫名其妙的「检查更新失败 HTTP 403」。
final class ReleaseFeedParserTests: XCTestCase {

    private let atom = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Release notes from my-window-pip</title>
      <entry>
        <id>tag:github.com,2008:Repository/1314000094/v0.1.8</id>
        <link rel="alternate" type="text/html" href="https://github.com/ljzxzxl/my-window-pip/releases/tag/v0.1.8"/>
        <title>v0.1.8</title>
      </entry>
      <entry>
        <link rel="alternate" type="text/html" href="https://github.com/ljzxzxl/my-window-pip/releases/tag/v0.1.7"/>
        <title>v0.1.7</title>
      </entry>
    </feed>
    """

    private let assets = """
    <div class="Box">
      <a href="/ljzxzxl/my-window-pip/releases/download/v0.1.8/MyWindowPip-0.1.8.dmg">dmg</a>
      <a href="/ljzxzxl/my-window-pip/releases/download/v0.1.8/MyWindowPip-0.1.8.dmg.sha256">sha</a>
      <a href="/ljzxzxl/my-window-pip/releases/download/v0.1.8/MyWindowPip-0.1.8.zip">zip</a>
    </div>
    """

    // MARK: - Atom feed

    func testAtomFeedPicksTheNewestEntry() {
        let found = ReleaseFeedParser.latestTag(from: atom)
        XCTAssertEqual(found?.tag, "v0.1.8")
        XCTAssertTrue(found?.pageURL?.absoluteString
                      == "https://github.com/ljzxzxl/my-window-pip/releases/tag/v0.1.8")
    }

    func testAtomFeedRejectsUnrecognisedContent() {
        XCTAssertNil(ReleaseFeedParser.latestTag(from: "<feed><title>no releases</title></feed>"))
        XCTAssertNil(ReleaseFeedParser.latestTag(from: ""))
    }

    // MARK: - expanded_assets

    func testExpandedAssetsFindsDMGAndChecksum() {
        let links = ReleaseFeedParser.assetLinks(from: assets)
        XCTAssertTrue(links.dmg?.absoluteString
                      == "https://github.com/ljzxzxl/my-window-pip/releases/download/v0.1.8/MyWindowPip-0.1.8.dmg")
        XCTAssertTrue(links.sha256?.absoluteString
                      == "https://github.com/ljzxzxl/my-window-pip/releases/download/v0.1.8/MyWindowPip-0.1.8.dmg.sha256")
    }

    func testExpandedAssetsAcceptsAbsoluteHrefs() {
        let html = """
        <a href="https://github.com/ljzxzxl/my-window-pip/releases/download/v0.1.9/MyWindowPip-0.1.9.dmg">dmg</a>
        """
        let links = ReleaseFeedParser.assetLinks(from: html)
        XCTAssertTrue(links.dmg?.lastPathComponent == "MyWindowPip-0.1.9.dmg")
        XCTAssertNil(links.sha256)
    }

    func testExpandedAssetsIgnoresUnrelatedLinks() {
        let html = """
        <a href="https://example.com/releases/download/v0.1.8/other.zip">zip</a>
        """
        let links = ReleaseFeedParser.assetLinks(from: html)
        XCTAssertNil(links.dmg)
        XCTAssertNil(links.sha256)
    }

    // MARK: - 403 的可读化

    private func response(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        let url = URL(string: "https://api.github.com/repos/ljzxzxl/my-window-pip/releases/latest")!
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/2",
                               headerFields: headers)!
    }

    func testRateLimited403ExplainsTheQuota() {
        let http = response(403, headers: [
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": "1794650537",
        ])
        let text = Updater.describeHTTPFailure(http)
        XCTAssertFalse(text.hasPrefix("HTTP "), "配额 403 不应再显示成裸状态码")
        XCTAssertTrue(text.contains("60"), "应说明每小时 60 次的上限")
    }

    func testRateLimited429IsExplainedToo() {
        let http = response(429, headers: ["X-RateLimit-Remaining": "0"])
        XCTAssertTrue(Updater.describeHTTPFailure(http).contains("60"))
    }

    func testOtherHTTPFailuresKeepTheirStatusCode() {
        XCTAssertEqual(Updater.describeHTTPFailure(response(500)), "HTTP 500")
        XCTAssertEqual(Updater.describeHTTPFailure(response(403)), "HTTP 403")
        XCTAssertEqual(Updater.describeHTTPFailure(
            response(403, headers: ["X-RateLimit-Remaining": "12"])), "HTTP 403")
    }
}
