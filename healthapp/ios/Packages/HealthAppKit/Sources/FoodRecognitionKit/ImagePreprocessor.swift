#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepares a meal photo for upload: applies EXIF orientation, downscales to `maxPixelSize` on the long edge,
/// re-encodes as JPEG and drops all metadata (EXIF, GPS, TIFF, maker notes) — the photo leaves the device
/// without location or device information (data minimisation).
public enum ImagePreprocessor {
    public enum PreprocessError: Error { case unreadableImage, encodingFailed }

    public static func prepareJPEG(from data: Data, maxPixelSize: Int = 1600, quality: Double = 0.8,
                                   maxBytes: Int = MealPhotoPipeline.maxUploadBytes) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw PreprocessError.unreadableImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // bake in orientation so we can drop EXIF
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw PreprocessError.unreadableImage }

        var q = quality
        while true {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw PreprocessError.encodingFailed
            }
            // Only the compression property is passed: no metadata dictionaries are copied.
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw PreprocessError.encodingFailed }
            if out.length <= maxBytes || q <= 0.3 { return out as Data }
            q -= 0.15
        }
    }
}
#endif
