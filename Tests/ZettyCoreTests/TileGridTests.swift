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

@Test func tooManyTilesScroll() {
    // 12 tiles need 3 rows; only two 160pt rows fit in 360pt, so it scrolls —
    // and the two visible rows split the height rather than sitting at the
    // 160pt floor with a dead stripe below them.
    let layout = TileGrid.layout(count: 12, width: 1200, height: 360,
                                 minTileWidth: 240, minTileHeight: 160, spacing: 8)
    #expect(layout.scrolls == true)
    #expect(layout.rows == 3)
    #expect(layout.tileHeight == (360.0 - 8.0) / 2.0)
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

// MARK: - TilesGrid (the configured cap)

@Test func tilesGridParsesColumnsByRows() {
    #expect(TilesGrid(parsing: "4x4") == TilesGrid(columns: 4, rows: 4))
    #expect(TilesGrid(parsing: "3X2") == TilesGrid(columns: 3, rows: 2))
    #expect(TilesGrid(parsing: "  5 x 1 ") == TilesGrid(columns: 5, rows: 1))
}

@Test func tilesGridRejectsNonsenseRatherThanGuessing() {
    #expect(TilesGrid(parsing: "four by four") == nil)
    #expect(TilesGrid(parsing: "4") == nil)
    #expect(TilesGrid(parsing: "4x") == nil)
    #expect(TilesGrid(parsing: "0x4") == nil)
    #expect(TilesGrid(parsing: "-2x3") == nil)
    #expect(TilesGrid(parsing: "") == nil)
}

@Test func tilesGridClampsAbsurdSizes() {
    #expect(TilesGrid(columns: 99, rows: 99) == TilesGrid(columns: 8, rows: 8))
    #expect(TilesGrid(columns: 0, rows: 0) == TilesGrid(columns: 1, rows: 1))
}

@Test func tilesGridRoundTripsThroughItsConfigValue() {
    let grid = TilesGrid(columns: 3, rows: 5)
    #expect(grid.configValue == "3x5")
    #expect(TilesGrid(parsing: grid.configValue) == grid)
}

// MARK: - The cap applied to layout

@Test func theConfiguredGridCapsColumns() {
    // 16 tiles would like 4 columns and gets them; 25 would like 5 and does not.
    let four = TileGrid.layout(count: 16, width: 1200, height: 800, grid: .default)
    #expect(four.columns == 4)
    let capped = TileGrid.layout(count: 25, width: 2400, height: 800, grid: .default)
    #expect(capped.columns == 4)
}

@Test func belowCapacityTilesStillGrowNearSquare() {
    let layout = TileGrid.layout(count: 6, width: 1200, height: 800, grid: .default)
    #expect(layout.columns == 3)
    #expect(layout.rows == 2)
    #expect(layout.scrolls == false)
}

@Test func aOneColumnGridStacksEverything() {
    let layout = TileGrid.layout(count: 6, width: 1200, height: 800,
                                 grid: TilesGrid(columns: 1, rows: 3))
    #expect(layout.columns == 1)
    #expect(layout.rows == 6)
    #expect(layout.scrolls == true)
}

@Test func scrollingFillsTheViewportRatherThanPinningToTheMinimum() {
    // 32 tiles at 4x4: 8 rows needed, 4 visible, so each visible row takes a
    // quarter of the height rather than the 160pt floor.
    let layout = TileGrid.layout(count: 32, width: 1200, height: 800,
                                 grid: .default, minTileHeight: 160, spacing: 12)
    #expect(layout.columns == 4)
    #expect(layout.rows == 8)
    #expect(layout.scrolls == true)
    #expect(layout.tileHeight == (800.0 - 36.0) / 4.0)
}

@Test func aShortWindowShowsFewerRowsThanConfigured() {
    // Only two 160pt rows fit in 360pt, even though the setting allows four.
    let layout = TileGrid.layout(count: 16, width: 1200, height: 360,
                                 grid: .default, minTileHeight: 160, spacing: 8)
    #expect(layout.scrolls == true)
    #expect(layout.tileHeight == (360.0 - 8.0) / 2.0)
}
