import Foundation
import Testing
@testable import ZettyCore

@Test func formatsAcrossMagnitudes() {
    #expect(ByteFormat.short(512) == "512 B")
    #expect(ByteFormat.short(16_384) == "16 KB")
    #expect(ByteFormat.short(432_013_312) == "412 MB")
}

@Test func gigabytesKeepOneDecimalSoTheNumberStillMoves() {
    // "1 GB" for anything between 1.0 and 1.9 makes the summary look frozen.
    #expect(ByteFormat.short(1_598_029_824) == "1.5 GB")
}

@Test func zeroIsRenderedNotBlank() {
    #expect(ByteFormat.short(0) == "0 B")
}

@Test func negativeBytesAreTreatedAsZeroRatherThanPrinted() {
    #expect(ByteFormat.short(-1) == "0 B")
}
