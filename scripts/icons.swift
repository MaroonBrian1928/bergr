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

// Miami: the tinted artwork's white figure on a violet-to-amber sunset, with palm fronds in the
// top-left corner. Drawn here instead of exported, so it follows the logo.
func renderMiami(into output: URL) {
    let size = 1024.0
    let input = root.appendingPathComponent("assets/logo-tinted.png")
    guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
          let logo = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let rgb = CGColorSpace(name: CGColorSpace.sRGB),
          let gray = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
          let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
              space: rgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fatalError("Cannot render \(input.path)")
    }
    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
    // Diagonal sunset, top-left violet to bottom-right amber (CoreGraphics' y points up).
    let colors = [color(0x5b1fa8), color(0x9b2a9a), color(0xe0457b), color(0xf59a3e)] as CFArray
    let gradient = CGGradient(colorsSpace: rgb, colors: colors, locations: [0, 0.38, 0.68, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    // A low sun glowing behind the figure's shoulder.
    let glow = CGGradient(colorsSpace: rgb, colors: [color(0xffd27a, 0.55), color(0xffd27a, 0)] as CFArray,
                          locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 820, y: 300), startRadius: 0,
                               endCenter: CGPoint(x: 820, y: 300), endRadius: 420, options: [])

    // Fronds: a curved stem with pointed leaflets drooping off both sides.
    func frond(from base: CGPoint, angle: CGFloat, length: CGFloat, droop: CGFloat) {
        let path = CGMutablePath()
        let steps = 17
        func point(_ t: CGFloat) -> CGPoint {
            let a = angle - droop * t * t
            // Integrate the bending direction approximately.
            let dx = cos(angle) * t + (cos(a) - cos(angle)) * t * 0.5
            let dy = sin(angle) * t + (sin(a) - sin(angle)) * t * 0.5
            return CGPoint(x: base.x + dx * length, y: base.y + dy * length)
        }
        for i in 1..<steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = point(t), q = point(t + 0.01)
            let dir = atan2(q.y - p.y, q.x - p.x)
            let leaf = length * 0.4 * sin(.pi * min(1, t * 1.1)) + 20
            for side in [-1.0, 1.0] {
                let out = dir + side * 0.8 - 0.4
                let tip = CGPoint(x: p.x + cos(out) * leaf, y: p.y + sin(out) * leaf)
                let width = leaf * 0.11
                let mid = CGPoint(x: (p.x + tip.x) / 2, y: (p.y + tip.y) / 2)
                let n = CGPoint(x: -sin(out) * width, y: cos(out) * width)
                path.move(to: p)
                path.addQuadCurve(to: tip, control: CGPoint(x: mid.x + n.x, y: mid.y + n.y))
                path.addQuadCurve(to: p, control: CGPoint(x: mid.x - n.x, y: mid.y - n.y))
            }
        }
        context.addPath(path)
        context.fillPath()
        let stem = CGMutablePath()
        stem.move(to: base)
        for i in 1...steps { stem.addLine(to: point(CGFloat(i) / CGFloat(steps))) }
        context.addPath(stem)
        context.setLineWidth(9)
        context.setLineCap(.round)
        context.strokePath()
    }
    context.setFillColor(color(0x2a0b4a, 0.72))
    context.setStrokeColor(color(0x2a0b4a, 0.72))
    let base = CGPoint(x: -30, y: 1060)
    frond(from: base, angle: -0.25, length: 520, droop: 0.9)
    frond(from: base, angle: -0.75, length: 470, droop: 0.7)
    frond(from: base, angle: -1.25, length: 400, droop: 0.5)

    // The logo in white, through the tinted artwork's lightness.
    gray.interpolationQuality = .high
    gray.draw(logo, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let mask = gray.makeImage() else { fatalError("Cannot mask the logo") }
    context.saveGState()
    context.clip(to: CGRect(x: 0, y: 0, width: size, height: size), mask: mask)
    context.setFillColor(color(0xffffff))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.restoreGState()

    try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let path = output.appendingPathComponent("icon-miami.png")
    guard let rendered = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Cannot encode \(path.path)") }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save \(path.path)") }
    print(path.path)
}
renderMiami(into: root.appendingPathComponent("bergr/Assets.xcassets/AppIcon-Miami.appiconset"))
