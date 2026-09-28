import Foundation
import XCTest

@testable import OI

@MainActor
final class WebURLResolverTests: XCTestCase {
    func testWebURLRecognizerRecognizesExplicitSchemeAndBareDomains() {
        XCTAssertEqual(
            WebURLResolver.recognize("https://github.com/apple/swift"),
            URL(string: "https://github.com/apple/swift")
        )
        XCTAssertEqual(
            WebURLResolver.recognize("http://EXAMPLE.com/path"),
            URL(string: "http://EXAMPLE.com/path")
        )
        XCTAssertEqual(
            WebURLResolver.recognize("ftp://files.example.com"),
            URL(string: "ftp://files.example.com")
        )
        XCTAssertEqual(
            WebURLResolver.recognize("github.com"),
            URL(string: "https://github.com")
        )
        XCTAssertEqual(
            WebURLResolver.recognize("GitHub.com/Forests?tab=readme"),
            URL(string: "https://GitHub.com/Forests?tab=readme")
        )
        XCTAssertEqual(
            WebURLResolver.recognize("example.io:8443/admin"),
            URL(string: "https://example.io:8443/admin")
        )
    }

    func testWebURLRecognizerRecognizesLocalhost() {
        XCTAssertEqual(
            WebURLResolver.recognize("localhost"),
            URL(string: "http://localhost")
        )
        XCTAssertEqual(
            WebURLResolver.recognize("localhost:3000"),
            URL(string: "http://localhost:3000")
        )
        XCTAssertEqual(
            WebURLResolver.recognize("http://localhost:8080/api"),
            URL(string: "http://localhost:8080/api")
        )
        XCTAssertEqual(
            WebURLResolver.recognize("127.0.0.1:5173"),
            URL(string: "http://127.0.0.1:5173")
        )
    }

    func testWebURLRecognizerDoesNotHijackSingleLabelQueries() {
        XCTAssertNil(WebURLResolver.recognize("app"))
        XCTAssertNil(WebURLResolver.recognize("tv"))
        XCTAssertNil(WebURLResolver.recognize("ai"))
        XCTAssertNil(WebURLResolver.recognize("dev"))
        XCTAssertNil(WebURLResolver.recognize("me"))
        XCTAssertNil(WebURLResolver.recognize("it"))
        XCTAssertNil(WebURLResolver.recognize("io"))
        XCTAssertNil(WebURLResolver.recognize("app:8080"))
        XCTAssertNil(WebURLResolver.recognize("app/"))
        XCTAssertNil(WebURLResolver.recognize(".app"))
        XCTAssertNil(WebURLResolver.recognize("app."))
        XCTAssertNil(WebURLResolver.recognize("example..com"))
    }

    func testWebURLRecognizerRejectsNonURLQueries() {
        XCTAssertNil(WebURLResolver.recognize("photo.png"))
        XCTAssertNil(WebURLResolver.recognize("report.pdf"))
        XCTAssertNil(WebURLResolver.recognize("1.5"))
        XCTAssertNil(WebURLResolver.recognize("192.168.1.1"))
        XCTAssertNil(WebURLResolver.recognize("foo@bar.com"))
        XCTAssertNil(WebURLResolver.recognize("example.abc"))
        XCTAssertNil(WebURLResolver.recognize("swift 并发指南"))
        XCTAssertNil(WebURLResolver.recognize("1 + 2"))
        XCTAssertNil(WebURLResolver.recognize(""))
        XCTAssertNil(WebURLResolver.recognize("   "))
    }

    func testWebURLResolverBuildsSearchURLWithEncoding() throws {
        let url = try XCTUnwrap(WebURLResolver.searchURL(for: "swift 并发"))
        XCTAssertEqual(url.absoluteString, "https://www.bing.com/search?q=swift%20%E5%B9%B6%E5%8F%91")
    }
}
