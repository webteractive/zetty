import Foundation
import Testing
@testable import ZettyCore

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("zetty-tiles-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func anAbsentFileLoadsAsAnEmptyLibrary() throws {
    #expect(TileProfileStore(directory: try tempDirectory()).load().profiles.isEmpty)
}

@Test func profilesSurviveASaveAndLoad() throws {
    let store = TileProfileStore(directory: try tempDirectory())
    var file = TileProfileFile()
    file.profiles = [TileProfile(name: "morning", grid: TilesGrid(columns: 2, rows: 2))]
    try store.save(file)
    #expect(store.load() == file)
}

@Test func aCorruptFileLoadsAsEmptyRatherThanThrowing() throws {
    let directory = try tempDirectory()
    try Data("{ not json".utf8)
        .write(to: directory.appendingPathComponent("tile-profiles.json"))
    #expect(TileProfileStore(directory: directory).load().profiles.isEmpty)
}
