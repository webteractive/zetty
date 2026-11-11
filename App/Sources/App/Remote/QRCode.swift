import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR codes for Tailscale sign-in pages, so a phone can approve a Mac that
/// is only reachable over SSH or a slow screen share.
enum QRCode {
    /// The code's modules (true = dark), without a border; nil if it can't
    /// be made.
    static func modules(for text: String) -> [[Bool]]? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Rows come out top first (CGContext memory starts at the top row).
        let rows = (0..<height).map { y in (0..<width).map { x in pixels[y * width + x] < 128 } }
        return trimmed(rows)
    }

    /// Rows as "1"/"0" strings for the CLI.
    static func rows(_ modules: [[Bool]]) -> [String] {
        modules.map { String($0.map { $0 ? "1" : "0" }) }
    }

    /// The code drawn dark on light in the scheme's own colors, inside the
    /// four-module border scanners expect.
    static func image(_ modules: [[Bool]], side: CGFloat) -> NSImage {
        let theme = ZTheme.current
        let ink = ZTheme.scheme.isDark ? theme.bg1Color : theme.fgColor
        let paper = ZTheme.scheme.isDark ? theme.fgColor : theme.bg1Color
        let count = CGFloat(modules.count + 8)
        return NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            paper.setFill()
            rect.fill()
            ink.setFill()
            // Whole points per module, centred: fractional ones blur into grey seams.
            let module = max(1, (rect.width / count).rounded(.down))
            let origin = ((rect.width - module * count) / 2).rounded(.down) + module * 4
            for (y, row) in modules.enumerated() {
                for (x, dark) in row.enumerated() where dark {
                    NSRect(x: origin + CGFloat(x) * module, y: origin + CGFloat(y) * module,
                           width: module, height: module).fill()
                }
            }
            return true
        }
    }

    /// Drops the light border Core Image adds, so callers choose their own.
    private static func trimmed(_ rows: [[Bool]]) -> [[Bool]]? {
        guard let top = rows.firstIndex(where: { $0.contains(true) }),
              let bottom = rows.lastIndex(where: { $0.contains(true) }) else { return nil }
        let kept = Array(rows[top...bottom])
        guard let left = kept.compactMap({ $0.firstIndex(of: true) }).min(),
              let right = kept.compactMap({ $0.lastIndex(of: true) }).max() else { return nil }
        return kept.map { Array($0[left...right]) }
    }
}
