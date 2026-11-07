// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreImage.CIFilterBuiltins
import UIKit
import XCTest
@testable import SimDeck

final class ESIMQRCodeReaderTests: XCTestCase {
    func testReadsActivationCodeFromPhotoData() throws {
        let code = "LPA:1$example.test$synthetic-code"
        XCTAssertEqual(ESIMQRCodeReader.activationCode(in: try qrImageData(for: code)), code)
    }

    func testIgnoresUnrelatedQRCode() throws {
        XCTAssertNil(ESIMQRCodeReader.activationCode(in: try qrImageData(for: "https://example.test")))
    }

    private func qrImageData(for value: String) throws -> Data {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        let image = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let cgImage = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        return try XCTUnwrap(UIImage(cgImage: cgImage).pngData())
    }
}
