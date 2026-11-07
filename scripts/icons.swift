#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Run from the repository root. Resize the approved artwork to opaque App Store PNGs.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
for (catalog, development) in [("AppIcon", false), ("AppIcon-Dev", true)] {
    let output = root.appendingPathComponent("bergr/Assets.xcassets/\(catalog).appiconset")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for appearance in ["light", "dark", "tinted"] {
        let variant = development && appearance != "tinted" ? "dev-\(appearance)" : appearance
        let input = root.appendingPathComponent("assets/logo-\(variant).png")
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1024, height: 1024,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            fatalError("Cannot render \(input.path)")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let path = output.appendingPathComponent("icon-\(appearance).png")
        guard let rendered = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(path as CFURL,
                  UTType.png.identifier as CFString, 1, nil) else {
            fatalError("Cannot encode \(path.path)")
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save \(path.path)") }
        print(path.path)
    }
}
