import Foundation
import Testing
@testable import Shiftio

@MainActor
struct RecentRingTests {
    @Test func recentRingHoldsUsedToolsThatFitTheFile() throws {
        let usage = ToolUsage(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        usage.record("jpg")
        usage.record("compress")
        usage.record("compress")
        usage.record("trim") // a video tool: does not fit a picture
        let png = URL(fileURLWithPath: "/tmp/a.png")
        let config = RingConfig(name: "Recent", center: nil, segments: ["tools:recent:4", "tools:frequent:3"])
        let ring = try #require(ResolvedRing(config, files: [png], resolution: RingResolution(tools: usage)))
        let ids = ring.segments.map(\.action.id)
        #expect(ids.contains("compress") && ids.contains("jpg"))
        #expect(!ids.contains("trim"))
        // Used twice, so it is frequent too, but it shows only once.
        #expect(ids.filter { $0 == "compress" }.count == 1)
    }
}
