// The test executable uses FSKit value objects and ordinary images, never a resource or device.
import Foundation
import FSKit
import XCTest

@objcMembers final class ValidationTests: XCTestCase {
    private func current() -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = .file
        attrs.mode = 0o100644
        attrs.uid = 501
        attrs.gid = 20
        attrs.flags = 0
        return attrs
    }

    private func expectError(_ code: Int32, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(code))
        }
    }

    func testUnsupportedChangeRejectsWholeRequestBeforeTruncate() {
        let request = FSItem.SetAttributesRequest()
        request.size = 0
        request.mode = 0o777
        expectError(ENOTSUP) { _ = try NTFSAttributePolicy.validate(request, current: current(), readOnly: false) }
        XCTAssertEqual(request.consumedAttributes, [])
    }

    func testUnchangedOwnershipAndModeAreAcknowledged() throws {
        let request = FSItem.SetAttributesRequest()
        request.mode = 0o644
        request.uid = 501
        request.gid = 20
        request.flags = 0
        let unchanged = try NTFSAttributePolicy.validate(request, current: current(), readOnly: false)
        XCTAssertEqual(unchanged, [.mode, .uid, .gid, .flags])
    }

    func testReadOnlyRejectsMetadataChanges() {
        let request = FSItem.SetAttributesRequest()
        request.flags = 0
        expectError(EROFS) { _ = try NTFSAttributePolicy.validate(request, current: current(), readOnly: true) }
    }

    func testOversizedFileCannotTrapDuringSignedConversion() {
        let request = FSItem.SetAttributesRequest()
        request.size = UInt64.max
        expectError(EFBIG) { _ = try NTFSAttributePolicy.validate(request, current: current(), readOnly: false) }
    }

    func testNonFileSizeRequestsAreIgnoredWithoutSignedConversion() throws {
        for type: FSItem.ItemType in [.directory, .symlink] {
            let attrs = current()
            attrs.type = type
            let request = FSItem.SetAttributesRequest()
            request.size = UInt64.max
            XCTAssertEqual(try NTFSAttributePolicy.validate(request, current: attrs, readOnly: false), [])
            XCTAssertEqual(request.consumedAttributes, [])
        }
    }

    func testUnsupportedDatesAreRejected() {
        for date in [timespec(tv_sec: -1, tv_nsec: 0), timespec(tv_sec: Int.max, tv_nsec: 0),
                     timespec(tv_sec: 1, tv_nsec: 1_000_000_000)] {
            let request = FSItem.SetAttributesRequest()
            request.modifyTime = date
            expectError(EINVAL) { _ = try NTFSAttributePolicy.validate(request, current: current(), readOnly: false) }
        }
    }

    func testValidTruncateAndEpochTimePassValidation() throws {
        let request = FSItem.SetAttributesRequest()
        request.size = 4096
        request.modifyTime = timespec(tv_sec: 0, tv_nsec: 0)
        XCTAssertEqual(try NTFSAttributePolicy.validate(request, current: current(), readOnly: false), [])
    }

    func testUnimplementedFlagsCannotReportSuccess() {
        let request = FSItem.SetAttributesRequest()
        request.flags = 2
        expectError(ENOTSUP) { _ = try NTFSAttributePolicy.validate(request, current: current(), readOnly: false) }
    }

    func testGeometryCannotOverflowOrAllocateWithInvalidAlignment() throws {
        for (block, count): (UInt64, UInt64) in [(0, 1), (512, 0), (513, 1024), (131072, 10),
                                                (4096, UInt64.max), (UInt64.max, 1)] {
            expectError(EINVAL) { _ = try NTFSResourceGeometry(blockSize: block, blockCount: count) }
        }
        let geometry = try NTFSResourceGeometry(blockSize: 512, blockCount: 12)
        XCTAssertEqual(geometry.bytes, 6144)
    }

}

let suite = XCTestSuite(name: "FSKit adapter without system resources")
suite.addTest(ValidationTests.defaultTestSuite)
suite.addTest(CreationTests.defaultTestSuite)
suite.addTest(VolumeTests.defaultTestSuite)
suite.run()
exit(suite.testRun?.hasSucceeded == true && suite.testCaseCount == 32 ? 0 : 1)
