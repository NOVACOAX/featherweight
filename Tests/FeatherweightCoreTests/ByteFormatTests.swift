import Testing

@testable import FeatherweightCore

struct ByteFormatTests {
    @Test func zeroIsNumeric() {
        let text = ByteFormat.string(0)
        #expect(text.contains("0"))
        #expect(!text.contains("Zero"))
    }
}
