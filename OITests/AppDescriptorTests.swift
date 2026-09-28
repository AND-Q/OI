import Foundation
import XCTest

@testable import OI

@MainActor
final class AppDescriptorTests: XCTestCase {
    func testAppDescriptorNormalizesURLAndUsesItAsIdentity() {
        let rawURL = URL(fileURLWithPath: "/tmp/OITests/../OITests/Demo.app")
        let descriptor = AppDescriptor(name: "Demo", url: rawURL)

        XCTAssertEqual(descriptor.url, rawURL.standardizedFileURL)
        XCTAssertEqual(descriptor.id, descriptor.url.path)
        XCTAssertEqual(descriptor.id, rawURL.standardizedFileURL.path)
    }
}
