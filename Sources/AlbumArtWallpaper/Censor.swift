import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum Censor {
    /// Chunky pixelation: roughly `blocks` squares across the shorter side, returned as JPEG data.
    static func pixelate(_ file: URL, blocks: CGFloat = 24) -> Data? {
        guard let input = CIImage(contentsOf: file, options: [.applyOrientationProperty: true]) else { return nil }
        let extent = input.extent

        let filter = CIFilter.pixellate()
        filter.inputImage = input
        filter.scale = Float(min(extent.width, extent.height) / blocks)
        filter.center = CGPoint(x: extent.minX, y: extent.minY)  // grid starts at the corner, so edge blocks are whole

        // The filter can bleed past the original bounds; crop back so the size is unchanged.
        guard let output = filter.outputImage?.cropped(to: extent),
              let cg = CIContext().createCGImage(output, from: extent)
        else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.95])
    }
}
