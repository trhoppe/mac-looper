import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func load(_ path: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(root.appendingPathComponent(path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "IconAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing icon master: \(path)"])
    }
    return image
}
func isOpaque(_ image: CGImage) -> Bool {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let byteCount = pixels.count
    return pixels.withUnsafeMutableBytes { memory in
        guard let context = CGContext(data: memory.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 3, to: byteCount, by: 4).allSatisfy { memory[$0] == 255 }
    }
}
func write(_ image: CGImage, size: Int, to url: URL, opaque: Bool) throws {
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "IconAssets", code: 2)
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let result = context.makeImage() else { throw NSError(domain: "IconAssets", code: 3) }
    CGImageDestinationAddImage(destination, result, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "IconAssets", code: 4) }
}
let mac = try load("Assets/AppIcon.png"), pad = try load("Assets/AppIcon-iPad.png")
guard isOpaque(pad) else { fatalError("The iPad icon master must be full-bleed and opaque; do not flatten an inset Mac tile.") }
for (set, image, opaque) in [("AppIconMac", mac, false), ("AppIconPad", pad, true)] {
    let directory = root.appendingPathComponent("Assets/Shared.xcassets/\(set).appiconset")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("Contents.json"))) as! [String: Any]
    for item in json["images"] as! [[String: String]] {
        let edge = Double(item["size"]!.components(separatedBy: "x")[0])!
        let scale = Double(item["scale"]!.dropLast())!
        try write(image, size: Int((edge * scale).rounded()), to: directory.appendingPathComponent(item["filename"]!), opaque: opaque)
    }
}
let artwork = root.appendingPathComponent("Assets/Shared.xcassets/LooperArtwork.imageset")
try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
try write(mac, size: 1024, to: artwork.appendingPathComponent("LooperArtwork.png"), opaque: false)
let manifest = """
{"images":[{"filename":"LooperArtwork.png","idiom":"universal"}],"info":{"author":"xcode","version":1}}
"""
try Data(manifest.utf8).write(to: artwork.appendingPathComponent("Contents.json"))
print("Generated Mac/iPad icon assets and welcome artwork; iPad assets have no alpha channel.")
