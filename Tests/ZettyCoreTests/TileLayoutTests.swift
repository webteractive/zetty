import Foundation
import Testing
@testable import ZettyCore

@Test func theBuiltInLayoutsCoverTheCommonShapes() {
    let names = TileLayout.builtIns.map(\.name)
    #expect(names == ["Focus", "Pair", "Stack", "Quad", "Grid"])
    #expect(TileLayout.builtIns.map(\.grid) == [
        TilesGrid(columns: 1, rows: 1),
        TilesGrid(columns: 2, rows: 1),
        TilesGrid(columns: 1, rows: 2),
        TilesGrid(columns: 2, rows: 2),
        TilesGrid(columns: 4, rows: 4),
    ])
}

@Test func everyBuiltInHasItsOwnIdentity() {
    let ids = Set(TileLayout.builtIns.map(\.id))
    #expect(ids.count == TileLayout.builtIns.count)
}

@Test func aLayoutRoundTripsThroughJSON() throws {
    let layout = TileLayout(name: "Wide", grid: TilesGrid(columns: 3, rows: 1))
    let data = try JSONEncoder().encode(layout)
    #expect(try JSONDecoder().decode(TileLayout.self, from: data) == layout)
}

@Test func aLayoutClampsAnAbsurdGrid() throws {
    let json = """
    {"id":"\(UUID().uuidString)","name":"huge","grid":{"columns":40,"rows":40}}
    """
    let decoded = try JSONDecoder().decode(TileLayout.self, from: Data(json.utf8))
    #expect(decoded.grid == TilesGrid(columns: 8, rows: 8))
}

@Test func anOlderLibraryWithoutLayoutsStillLoads() throws {
    // Written before layouts existed: the key is simply absent.
    let json = #"{"profiles":[]}"#
    let decoded = try JSONDecoder().decode(TileProfileFile.self, from: Data(json.utf8))
    #expect(decoded.layouts.isEmpty)
    #expect(decoded.profiles.isEmpty)
}

@Test func aLibraryRoundTripsItsLayouts() throws {
    var file = TileProfileFile()
    file.layouts = TileLayout.builtIns
    file.profiles = [TileProfile(name: "morning", grid: TilesGrid(columns: 2, rows: 2))]
    let data = try JSONEncoder().encode(file)
    #expect(try JSONDecoder().decode(TileProfileFile.self, from: data) == file)
}
