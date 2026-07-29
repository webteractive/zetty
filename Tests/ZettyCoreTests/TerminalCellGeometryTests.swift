import CoreGraphics
import Testing
@testable import ZettyCore

private let cellW: CGFloat = 8
private let cellH: CGFloat = 16
private let viewHeight: CGFloat = 160   // 10 rows

@Test func cellCenterIsTheMiddleOfTheCell() {
    let point = TerminalCellGeometry.cellCenter(row: 0, col: 0, cellW: cellW, cellH: cellH)
    #expect(point == CGPoint(x: 4, y: 8))
}

@Test func cellCenterAdvancesByCellSize() {
    let point = TerminalCellGeometry.cellCenter(row: 2, col: 3, cellW: cellW, cellH: cellH)
    #expect(point == CGPoint(x: 28, y: 40))
}

@Test func viewPointFlipsY() {
    let flipped = TerminalCellGeometry.viewPoint(fromGhostty: CGPoint(x: 10, y: 40),
                                                viewHeight: viewHeight)
    #expect(flipped == CGPoint(x: 10, y: 120))
}

@Test func cellRoundTripsThroughViewSpace() {
    for row in 0..<10 {
        for col in 0..<20 {
            let ghostty = TerminalCellGeometry.cellCenter(row: row, col: col,
                                                          cellW: cellW, cellH: cellH)
            let view = TerminalCellGeometry.viewPoint(fromGhostty: ghostty, viewHeight: viewHeight)
            let back = TerminalCellGeometry.cell(atViewPoint: view, viewHeight: viewHeight,
                                                 cellW: cellW, cellH: cellH)
            #expect(back?.row == row)
            #expect(back?.col == col)
        }
    }
}

@Test func cellRejectsPointsOutsideTheView() {
    #expect(TerminalCellGeometry.cell(atViewPoint: CGPoint(x: -1, y: 10),
                                      viewHeight: viewHeight, cellW: cellW, cellH: cellH) == nil)
    #expect(TerminalCellGeometry.cell(atViewPoint: CGPoint(x: 10, y: -1),
                                      viewHeight: viewHeight, cellW: cellW, cellH: cellH) == nil)
    #expect(TerminalCellGeometry.cell(atViewPoint: CGPoint(x: 10, y: 200),
                                      viewHeight: viewHeight, cellW: cellW, cellH: cellH) == nil)
}

@Test func cellRejectsDegenerateMetrics() {
    #expect(TerminalCellGeometry.cell(atViewPoint: CGPoint(x: 10, y: 10),
                                      viewHeight: viewHeight, cellW: 0, cellH: cellH) == nil)
    #expect(TerminalCellGeometry.cell(atViewPoint: CGPoint(x: 10, y: 10),
                                      viewHeight: viewHeight, cellW: cellW, cellH: 0) == nil)
}

@Test func cellSpanRectCoversTheWholeRunInViewSpace() {
    // Row 0, columns 2…4 → x 16, width 24; row 0 is the TOP row, so in
    // bottom-left view space its y is viewHeight - cellH.
    let rect = TerminalCellGeometry.cellSpanRect(row: 0, colStart: 2, colEnd: 4,
                                                 viewHeight: viewHeight,
                                                 cellW: cellW, cellH: cellH)
    #expect(rect == CGRect(x: 16, y: 144, width: 24, height: 16))
}

@Test func cellSpanRectHandlesASingleCell() {
    let rect = TerminalCellGeometry.cellSpanRect(row: 1, colStart: 0, colEnd: 0,
                                                 viewHeight: viewHeight,
                                                 cellW: cellW, cellH: cellH)
    #expect(rect == CGRect(x: 0, y: 128, width: 8, height: 16))
}
