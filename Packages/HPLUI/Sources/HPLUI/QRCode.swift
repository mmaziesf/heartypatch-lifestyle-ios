#if canImport(CoreImage) && canImport(CoreImage.CIFilterBuiltins)
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Pairing QR (CoreImage, on device; no network, no third-party library).
enum QRCode {
    static func image(_ text: String, scale: CGFloat = 8) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
#endif
