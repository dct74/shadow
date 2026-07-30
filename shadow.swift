import Foundation
import AppKit
import CoreGraphics
import UniformTypeIdentifiers
// MARK: - Color Control
private let colorReset = "\u{001B}[0m"
private let colorGreen = "\u{001B}[32m"
private let colorRed = "\u{001B}[31m"
// MARK: - macOS Squircle Path
/// Creates a "squircle" (continuous-curvature rounded rectangle) path using a superellipse with
/// exponent 0.4 to approximate Apple's native corner style.
private func createRoundedRectPath(for rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2)
    let path = CGMutablePath()

    // Sharp corners — use a plain rectangle path.
    if r <= 0 {
        path.addRect(rect)
        return path
    }

    let exponent: CGFloat = 0.4
    let steps = max(Int(r), 10)
    var cornerPoints: [CGPoint] = []
    for i in 0...steps {
        let angle = CGFloat(i) / CGFloat(steps) * (.pi / 2.0)
        let x = r * pow(cos(angle), exponent)
        let y = r * pow(sin(angle), exponent)
        cornerPoints.append(CGPoint(x: x, y: y))
    }
    let rbCenter = CGPoint(x: rect.maxX - r, y: rect.minY + r)
    path.move(to: CGPoint(x: rect.maxX, y: rect.minY + r))
    for p in cornerPoints.dropFirst() {
        path.addLine(to: CGPoint(x: rbCenter.x + p.x, y: rbCenter.y - p.y))
    }
    path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
    let lbCenter = CGPoint(x: rect.minX + r, y: rect.minY + r)
    for p in cornerPoints.dropFirst() {
        path.addLine(to: CGPoint(x: lbCenter.x - p.y, y: lbCenter.y - p.x))
    }
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
    let ltCenter = CGPoint(x: rect.minX + r, y: rect.maxY - r)
    for p in cornerPoints.dropFirst() {
        path.addLine(to: CGPoint(x: ltCenter.x - p.x, y: ltCenter.y + p.y))
    }
    path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
    let rtCenter = CGPoint(x: rect.maxX - r, y: rect.maxY - r)
    for p in cornerPoints.dropFirst() {
        path.addLine(to: CGPoint(x: rtCenter.x + p.y, y: rtCenter.y + p.x))
    }
    path.closeSubpath()
    return path
}
// MARK: - White Alpha Mask (RGBA, transparent background)

/// Creates a solid-white image whose alpha channel matches the input image.
/// The result is used as a mask to draw clean, anti-aliased drop shadows.
private func makeWhiteAlphaMask(from image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    context.clip(to: rect, mask: image)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(rect)
    return context.makeImage()
}
// MARK: - Main Processor: Squircle Crop + Two-Layer Shadow

/// Max pixel count (width × height) before a warning is emitted.
private let maxPixelCount: Int = 50_000_000  // ~50 MP

/// Applies a macOS-style two-layer drop shadow (ambient + contact) to an image,
/// crops it with a squircle corner radius, and writes the result as PNG into a
/// `shadow/` subdirectory next to the source file.
///
/// - Parameter includeExtensionInName: When `true`, the extension is embedded in
///   the output filename (e.g. `photo_png_shadow.png`).  Used internally by the
///   batch processor to disambiguate files that share a basename in the same
///   directory.  Callers outside `processPaths` should leave this at its default.
func addWindowLikeShadow(to filePath: String, cornerRadius: CGFloat = 96, includeExtensionInName: Bool = false) throws {
    try autoreleasepool {
        let fileURL = URL(fileURLWithPath: filePath)
        let resolvedFileURL = fileURL.resolvingSymlinksInPath()

        // Preserve useful metadata but strip EXIF orientation (the new image is
        // already rendered in the correct orientation).
        var imageProperties: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithURL(resolvedFileURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            var filtered = props
            filtered.removeValue(forKey: kCGImagePropertyOrientation)
            imageProperties = filtered
        }

        guard let nsImage = NSImage(contentsOf: resolvedFileURL),
              let inputCGImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "ImageError", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to read image or unsupported format."])
        }

        let origWidth = CGFloat(inputCGImage.width)
        let origHeight = CGFloat(inputCGImage.height)

        // Warn if the image is very large and may consume excessive memory.
        if Int(origWidth * origHeight) > maxPixelCount {
            let mp = (Double(origWidth * origHeight) / 1_000_000).rounded()
            fputs("⚠️  Large image (\(Int(origWidth))×\(Int(origHeight)), ~\(Int(mp)) MP) — may use significant memory.\n", stderr)
        }

        // 1. Render rounded-corner image
        let origSize = CGSize(width: origWidth, height: origHeight)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let roundedContext = CGContext(data: nil, width: Int(origWidth), height: Int(origHeight), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw NSError(domain: "ContextError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create temp context."])
        }
        let origRect = CGRect(origin: .zero, size: origSize)
        let roundedPath = createRoundedRectPath(for: origRect, radius: cornerRadius)
        roundedContext.addPath(roundedPath)
        roundedContext.clip()
        roundedContext.draw(inputCGImage, in: origRect)
        guard let roundedCGImage = roundedContext.makeImage() else {
            throw NSError(domain: "RenderError", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to create rounded image."])
        }
        // 2. Create white mask from rounded alpha (clean shadow shape)
        guard let maskImage = makeWhiteAlphaMask(from: roundedCGImage) else {
            throw NSError(domain: "MaskError", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create mask image."])
        }
        // 3. Draw two-layer shadow on canvas
        let padding: CGFloat = 150.0
        let ambientShadowOffset = CGSize(width: 0, height: -16)
        let ambientShadowBlur: CGFloat = 80.0
        let ambientShadowColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.1)
        let contactShadowOffset = CGSize(width: 0, height: -24)
        let contactShadowBlur: CGFloat = 55.0
        let contactShadowColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.3)

        let newWidth = origWidth + padding * 1.5
        let newHeight = origHeight + padding * 1.5
        guard let context = CGContext(data: nil, width: Int(newWidth), height: Int(newHeight), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw NSError(domain: "ContextError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create graphics context."])
        }
        let drawRect = CGRect(x: padding * 0.75, y: padding * 0.75, width: origWidth, height: origHeight)
        // Ambient shadow (wide, soft)
        context.saveGState()
        context.setShadow(offset: ambientShadowOffset, blur: ambientShadowBlur, color: ambientShadowColor)
        context.draw(maskImage, in: drawRect)
        context.restoreGState()
        // Contact shadow (tighter, darker)
        context.saveGState()
        context.setShadow(offset: contactShadowOffset, blur: contactShadowBlur, color: contactShadowColor)
        context.draw(maskImage, in: drawRect)
        context.restoreGState()
        // Rounded image on top
        context.draw(roundedCGImage, in: drawRect)
        guard let finalCGImage = context.makeImage() else {
            throw NSError(domain: "RenderError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Image compose failed."])
        }
        // Disambiguate by appending the extension when the same basename
        // appears with different extensions (e.g. photo.png → photo_png_shadow.png).
        // Spaces in the basename are replaced with underscores.
        let baseFilename = resolvedFileURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
        let originalFilename: String
        if includeExtensionInName {
            let ext = resolvedFileURL.pathExtension
            originalFilename = "\(baseFilename)_\(ext)"
        } else {
            originalFilename = baseFilename
        }
        let newFilename = "\(originalFilename)_shadow.png"
        let shadowDir = resolvedFileURL.deletingLastPathComponent().appendingPathComponent("shadow")
        try FileManager.default.createDirectory(at: shadowDir, withIntermediateDirectories: true, attributes: nil)
        let outputURL = shadowDir.appendingPathComponent(newFilename)
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "WriteError", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination."])
        }
        CGImageDestinationAddImage(destination, finalCGImage, imageProperties as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            throw NSError(domain: "WriteError", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize image write."])
        }
    }
}
// MARK: - Image File Discovery

/// Recursively enumerates image files in `directoryPath` and returns their
/// absolute paths sorted alphabetically.  Supported extensions:
/// png, jpg, jpeg, bmp, tiff, tif, webp.
func getImagePaths(in directoryPath: String) -> [String] {
    let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp", "tiff", "tif", "webp"]
    var paths: [String] = []
    let dirURL = URL(fileURLWithPath: directoryPath)
    guard let enumerator = FileManager.default.enumerator(
        at: dirURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        fputs("⚠️  Cannot access directory: \(directoryPath)\n", stderr)
        return paths
    }
    for case let fileURL as URL in enumerator {
        if allowedExtensions.contains(fileURL.pathExtension.lowercased()) {
            paths.append(fileURL.path)
        }
    }
    return paths.sorted()
}
// MARK: - Batch Processor

func processPaths(_ dropPaths: [String]) async {
    var allFilePaths: [String] = []
    for path in dropPaths {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            if isDir.boolValue {
                let imagePaths = getImagePaths(in: path)
                if imagePaths.isEmpty {
                    fputs("ℹ️  No image files found in folder: \(path)\n", stderr)
                } else {
                    allFilePaths.append(contentsOf: imagePaths)
                }
            } else {
                allFilePaths.append(path)
            }
        } else {
            fputs("⚠️  Path does not exist, skipping: \(path)\n", stderr)
        }
    }
    // Deduplicate in case the same file appears more than once (e.g. passed
    // explicitly and also found inside a directory).
    var seen = Set<String>()
    allFilePaths = allFilePaths.filter { seen.insert($0).inserted }

    if allFilePaths.isEmpty { return }

    let total = allFilePaths.count
    fputs("Start processing \(total) files\n", stderr)

    // Detect basename collisions per output directory so we can disambiguate
    // only when files really land in the same shadow/ folder.
    var pathKey: [String: String] = [:]    // path → "outputDir\0basename"
    var keyCounts: [String: Int] = [:]
    for path in allFilePaths {
        let dir = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            .deletingLastPathComponent().path
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let key = "\(dir)\0\(base)"
        pathKey[path] = key
        keyCounts[key, default: 0] += 1
    }
    let disambiguatePaths = Set(
        pathKey.filter { keyCounts[$0.value, default: 0] > 1 }.keys
    )

    typealias TaskResult = (path: String, ok: Bool, errorMessage: String)
    let concurrencyLimit = max(1, ProcessInfo.processInfo.activeProcessorCount)

    let results = await withTaskGroup(of: TaskResult.self) { group in
        var iterator = allFilePaths.enumerated().makeIterator()

        // Seed the initial batch.
        for _ in 0..<min(concurrencyLimit, total) {
            guard let (index, path) = iterator.next() else { break }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let disambiguate = disambiguatePaths.contains(path)
            fputs("  [\(index + 1)/\(total)] \(name)\n", stderr)
            group.addTask {
                do {
                    try addWindowLikeShadow(to: path, includeExtensionInName: disambiguate)
                    return (path, true, "")
                } catch {
                    return (path, false, error.localizedDescription)
                }
            }
        }

        var successCount = 0
        var failCount = 0
        var errors: [String] = []

        // For each completed task, enqueue the next file (if any).
        while let result = await group.next() {
            if result.ok {
                successCount += 1
            } else {
                errors.append("❌ Failed [\(result.path)]: \(result.errorMessage)")
                failCount += 1
            }
            if let (index, path) = iterator.next() {
                let name = URL(fileURLWithPath: path).lastPathComponent
                let disambiguate = disambiguatePaths.contains(path)
                fputs("  [\(index + 1)/\(total)] \(name)\n", stderr)
                group.addTask {
                    do {
                        try addWindowLikeShadow(to: path, includeExtensionInName: disambiguate)
                        return (path, true, "")
                    } catch {
                        return (path, false, error.localizedDescription)
                    }
                }
            }
        }

        return (successCount: successCount, failCount: failCount, errors: errors)
    }

    for error in results.errors { fputs("\(error)\n", stderr) }
    let result = "Done: \(colorGreen)succeeded \(results.successCount)\(colorReset), \(colorRed)failed \(results.failCount)\(colorReset)\n"
    fputs(result, stderr)
}
// MARK: - Entry Point
if CommandLine.arguments.count > 1 {
    await processPaths(Array(CommandLine.arguments.dropFirst()))
} else {
    fputs("Usage: add-shadow <file_or_folder_path> [...]\n", stderr)
}
