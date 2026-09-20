import Foundation
import Testing
@testable import ZettyCore

@Test func zeroTilesProducesAnEmptyLayout() {
    let layout = TileGrid.layout(count: 0, width: 1200, height: 800)
    #expect(layout.columns == 0)
    #expect(layout.rows == 0)
    #expect(layout.scrolls == false)
}

@Test func oneTileFillsTheArea() {
    let layout = TileGrid.layout(count: 1, width: 1200, height: 800)
    #expect(layout.columns == 1)
    #expect(layout.rows == 1)
    #expect(layout.tileWidth == 1200)
    #expect(layout.tileHeight == 800)
    #expect(layout.scrolls == false)
}

@Test func fourTilesMakeASquare() {
    let layout = TileGrid.layout(count: 4, width: 1200, height: 800)
    #expect(layout.columns == 2)
    #expect(layout.rows == 2)
}

@Test func sixTilesInAWideWindowMakeThreeColumns() {
    let layout = TileGrid.layout(count: 6, width: 1200, height: 800)
    #expect(layout.columns == 3)
    #expect(layout.rows == 2)
}

@Test func tileWidthAccountsForSpacingBetweenColumns() {
    // 3 columns, 2 gaps of 8 -> (1200 - 16) / 3
    let layout = TileGrid.layout(count: 6, width: 1200, height: 800, spacing: 8)
    let expected = (1200.0 - 16.0) / 3.0
    #expect(layout.tileWidth == expected)
}

@Test func aNarrowWindowFallsBackToOneColumn() {
    let layout = TileGrid.layout(count: 6, width: 300, height: 800, minTileWidth: 240)
    #expect(layout.columns == 1)
    #expect(layout.rows == 6)
}

@Test func tooManyTilesScrollAtTheMinimumHeight() {
    let layout = TileGrid.layout(count: 12, width: 1200, height: 360,
                                 minTileWidth: 240, minTileHeight: 160, spacing: 8)
    #expect(layout.scrolls == true)
    #expect(layout.tileHeight == 160)
    #expect(layout.rows == 3)
}

@Test func aGridThatFitsDoesNotScroll() {
    let layout = TileGrid.layout(count: 4, width: 1200, height: 800,
                                 minTileWidth: 240, minTileHeight: 160)
    #expect(layout.scrolls == false)
    #expect(layout.tileHeight > 160)
}

@Test func columnsNeverExceedWhatTheWidthAllows() {
    // 9 tiles would like 3 columns; 560pt only fits 2 at a 240pt minimum.
    let layout = TileGrid.layout(count: 9, width: 560, height: 2000,
                                 minTileWidth: 240, spacing: 8)
    #expect(layout.columns == 2)
    #expect(layout.rows == 5)
}
