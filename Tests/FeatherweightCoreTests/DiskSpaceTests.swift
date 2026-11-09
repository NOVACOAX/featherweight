import Foundation
import Testing

@testable import FeatherweightCore

struct DiskSpaceTests {
    @Test func diskSpaceForHome() throws {
        let space = try DiskSpace.forVolume(containing: FileManager.default.homeDirectoryForCurrentUser)
        #expect(space.free > 0)
        #expect(space.total > space.free)
    }
}
