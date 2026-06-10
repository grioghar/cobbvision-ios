import XCTest
import CVCore
@testable import CVCapture

final class FormatPickerTests: XCTestCase {
    // Roughly an iPhone camera's format table.
    private let formats = [
        FormatDescriptor(width: 1280, height: 720, maxFrameRate: 60, isMultiCamSupported: true, index: 0),
        FormatDescriptor(width: 1920, height: 1080, maxFrameRate: 30, isMultiCamSupported: true, index: 1),
        FormatDescriptor(width: 1920, height: 1080, maxFrameRate: 60, isMultiCamSupported: false, index: 2),
        FormatDescriptor(width: 3840, height: 2160, maxFrameRate: 30, isMultiCamSupported: false, index: 3),
        FormatDescriptor(width: 3840, height: 2160, maxFrameRate: 60, isMultiCamSupported: false, index: 4),
    ]

    func testPicksSmallestSatisfyingFormat() {
        let choice = FormatPicker.pick(formats: formats, quality: .hd1080_30, requireMultiCam: false)
        XCTAssertEqual(choice?.format.index, 1, "1080p30 should not grab a 4K format")
        XCTAssertEqual(choice?.frameRate, 30)
        XCTAssertEqual(choice?.effectiveQuality, .hd1080_30)
    }

    func test4KAvailableWhenSingleCam() {
        let choice = FormatPicker.pick(formats: formats, quality: .uhd4k_30, requireMultiCam: false)
        XCTAssertEqual(choice?.format.index, 3)
        XCTAssertEqual(choice?.effectiveQuality, .uhd4k_30)
    }

    func testMultiCamStepsDownWhenFormatNotSupported() {
        // 4K isn't multi-cam capable on this table → ladder: 4K → 1080p30.
        let choice = FormatPicker.pick(formats: formats, quality: .uhd4k_30, requireMultiCam: true)
        XCTAssertEqual(choice?.effectiveQuality, .hd1080_30)
        XCTAssertEqual(choice?.format.index, 1)
        XCTAssertTrue(choice!.format.isMultiCamSupported)
    }

    func testMultiCam1080p60StepsDownTo1080p30() {
        // The only 60 fps 1080p format isn't multi-cam capable.
        let choice = FormatPicker.pick(formats: formats, quality: .hd1080_60, requireMultiCam: true)
        XCTAssertEqual(choice?.effectiveQuality, .hd1080_30)
    }

    func testNoUsableFormatReturnsNil() {
        let tiny = [FormatDescriptor(width: 640, height: 480, maxFrameRate: 30, isMultiCamSupported: true, index: 0)]
        XCTAssertNil(FormatPicker.pick(formats: tiny, quality: .hd720_30, requireMultiCam: false))
    }

    func testEmptyFormatListReturnsNil() {
        XCTAssertNil(FormatPicker.pick(formats: [], quality: .hd720_30, requireMultiCam: true))
    }
}
