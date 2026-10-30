import XCTest

@testable import CloudDiskKit

final class SmokeTests: XCTestCase {
    func testDriveDateParsesFractionalSeconds() {
        XCTAssertNotNil(DriveDate.parse("2026-10-29T23:12:04.500Z"))
        XCTAssertNotNil(DriveDate.parse("2026-10-29T23:12:04Z"))
        XCTAssertNil(DriveDate.parse("not-a-date"))
    }
}
