import Foundation
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - Color Control
private let colorReset = "\u{001B}[0m"
private let colorGreen = "\u{001B}[32m"
private let colorRed = "\u{001B}[31m"

// MARK: - 处理过程旋转动画
private func startSpinner(message: String) -> Task<Void, Never> {
    Task {
        let frames = ["-", "\\", "|", "/"]
        var idx = 0
        while !Task.isCancelled {
            fputs("\r\(frames[idx]) \(message)", stderr)
            fflush(stderr)
            try? await Task.sleep(nanoseconds: 100_000_000)
            idx = (idx + 1) % frames.count
        }
        let clearLine = String(repeating: " ", count: message.count + 10)
        fputs("\r\(clearLine)\r", stderr)
        fflush(stderr)
    }
}

// MARK: - 提取 Alpha 遮罩
private func makeAlphaMask(from image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height
    guard let context = CGContext(data: nil, 
                                  width: width, 
                                  height: height, 
                                  bitsPerComponent: 8, 
                                  bytesPerRow: 0, 
                                  space: CGColorSpaceCreateDeviceGray(), 
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { 
        return nil 
    }
    
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    context.clip(to: rect, mask: image)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(rect)
    
    return context.makeImage()
}

// MARK: - 核心处理函数 双层阴影完美复刻
func addWindowLikeShadow(to filePath: String) throws {
    let fileURL = URL(fileURLWithPath: filePath)
    let resolvedFileURL = fileURL.resolvingSymlinksInPath()
    
    var imageProperties: [CFString: Any] = [:]
    if let source = CGImageSourceCreateWithURL(resolvedFileURL as CFURL, nil),
       let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
        imageProperties = props
    }
    
    guard let nsImage = NSImage(contentsOf: resolvedFileURL), let inputCGImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw NSError(domain: "ImageError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read image or unsupported format."])
    }
    
    let origWidth = CGFloat(inputCGImage.width)
    let origHeight = CGFloat(inputCGImage.height)
    
    let padding: CGFloat = 130.0
    let shadow1Offset = CGSize(width: 0, height: -8)
    let shadow1Blur: CGFloat = 70.0
    let shadow1Color = CGColor(red: 0, green: 0, blue: 0, alpha: 0.1)
    let shadow2Offset = CGSize(width: 0, height: -18)
    let shadow2Blur: CGFloat = 50.0
    let shadow2Color = CGColor(red: 0, green: 0, blue: 0, alpha: 0.30)
    
    let newWidth = origWidth + padding * 2
    let newHeight = origHeight + padding * 2
    let colorSpace = inputCGImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    
    guard let context = CGContext(data: nil, width: Int(newWidth), height: Int(newHeight), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
        throw NSError(domain: "ContextError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create graphics context."])
    }
    
    let drawRect = CGRect(x: padding, y: padding, width: origWidth, height: origHeight)
    
    guard let maskImage = makeAlphaMask(from: inputCGImage) else {
        throw NSError(domain: "MaskError", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to create mask image."])
    }
    
    context.saveGState()
    context.setShadow(offset: shadow1Offset, blur: shadow1Blur, color: shadow1Color)
    context.draw(maskImage, in: drawRect)
    context.restoreGState()
    
    context.saveGState()
    context.setShadow(offset: shadow2Offset, blur: shadow2Blur, color: shadow2Color)
    context.draw(maskImage, in: drawRect)
    context.restoreGState()
    
    context.draw(inputCGImage, in: drawRect)
    
    guard let finalCGImage = context.makeImage() else {
        throw NSError(domain: "RenderError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Image compose failed."])
    }
    
    let originalFilename = resolvedFileURL.deletingPathExtension().lastPathComponent
    let newFilename = "\(originalFilename)_shadow.png"
    let shadowDir = resolvedFileURL.deletingLastPathComponent().appendingPathComponent("shadow")
    try FileManager.default.createDirectory(at: shadowDir, withIntermediateDirectories: true, attributes: nil)
    let outputURL = shadowDir.appendingPathComponent(newFilename)
    
    guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "WriteError", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination."])
    }
    
    CGImageDestinationAddImage(destination, finalCGImage, imageProperties as CFDictionary)
    
    if !CGImageDestinationFinalize(destination) {
        throw NSError(domain: "WriteError", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize image write."])
    }
}

// MARK: - 获取文件夹内所有图片路径
func getImagePaths(in directoryPath: String) -> [String] {
    let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp", "tiff", "tif", "webp"]
    var paths: [String] = []
    let dirURL = URL(fileURLWithPath: directoryPath)
    
    guard let enumerator = FileManager.default.enumerator(at: dirURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return paths }
    
    for case let fileURL as URL in enumerator {
        if allowedExtensions.contains(fileURL.pathExtension.lowercased()) {
            paths.append(fileURL.path)
        }
    }
    return paths.sorted()
}

// MARK: - 核心调度逻辑
func processPaths(_ dropPaths: [String]) async {
    var allFilePaths: [String] = []
    for path in dropPaths {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            if isDir.boolValue {
                let imagePaths = getImagePaths(in: path)
                if imagePaths.isEmpty { fputs("ℹ️ No image files found in folder: \(path)\n", stderr) }
                else { allFilePaths.append(contentsOf: imagePaths) }
            } else {
                allFilePaths.append(path)
            }
        }
    }
    
    if allFilePaths.isEmpty { return }
    
    fputs("Start processing \(allFilePaths.count) files\n", stderr)
    let spinner = startSpinner(message: "Processing \(allFilePaths.count) files...")
    var successCount = 0
    var failCount = 0
    var errors: [String] = []
    
    for path in allFilePaths {
        do {
            try addWindowLikeShadow(to: path)
            successCount += 1
        } catch {
            errors.append("❌ Failed [\(path)]: \(error.localizedDescription)")
            failCount += 1
        }
    }
    
    spinner.cancel()
    await spinner.value
    
    for error in errors { fputs("\(error)\n", stderr) }
    
    let result = "Done: \(colorGreen)successed \(successCount)\(colorReset), \(colorRed)failed \(failCount)\(colorReset)\n"
    fputs(result, stderr)
}

// MARK: - 程序入口
if CommandLine.arguments.count > 1 {
    await processPaths(Array(CommandLine.arguments.dropFirst()))
} else {
    fputs("Usage: add-shadow <file_or_folder_path> [...]\n", stderr)
}
