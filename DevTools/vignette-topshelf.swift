// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Darkens the top shelf images toward their edges, and heavily along the bottom, so tvOS's
// own blur of the "dock" region has less bright artwork to smear. Always reads the pristine
// copies in TopShelfOriginals and overwrites the asset catalog's, so it can be re-run.
// Usage: swift DevTools/vignette-topshelf.swift   (from the ATVQ folder)

import AppKit

let brand = "ATVQ/ATVQ/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
let jobs: [(String, String)] = [
    ("topshelf-1920@1x", "Top Shelf Image.imageset/topshelf@1x.png"),
    ("topshelf-1920@2x", "Top Shelf Image.imageset/topshelf@2x.png"),
    ("topshelf-2320@1x", "Top Shelf Image Wide.imageset/topshelf@1x.png"),
    ("topshelf-2320@2x", "Top Shelf Image Wide.imageset/topshelf@2x.png"),
]

func vignette(_ source: CGImage) -> CGImage {
    let w = source.width, h = source.height
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
    let size = CGSize(width: w, height: h)

    // Edges: transparent through the middle, then rising to black at the corners (elliptical).
    let radial = CGGradient(colorSpace: space, colorComponents: [0, 0, 0, 0,  0, 0, 0, 0.18,  0, 0, 0, 0.62],
                            locations: [0, 0.6, 1], count: 3)!
    ctx.saveGState()
    ctx.translateBy(x: size.width / 2, y: size.height / 2)
    ctx.scaleBy(x: size.width / size.height, y: 1)
    ctx.drawRadialGradient(radial, startCenter: .zero, startRadius: 0, endCenter: .zero,
                           endRadius: size.height * 0.9, options: .drawsAfterEndLocation)
    ctx.restoreGState()

    // Bottom: a steady ramp starting a bit under halfway, nearly black across the lowest edge.
    let bottom = CGGradient(colorSpace: space, colorComponents: [0, 0, 0, 0,  0, 0, 0, 0.55,  0, 0, 0, 0.92],
                            locations: [0, 0.65, 1], count: 3)!
    ctx.drawLinearGradient(bottom, start: CGPoint(x: 0, y: size.height * 0.55), end: CGPoint(x: 0, y: 0), options: [])
    return ctx.makeImage()!
}

for (original, target) in jobs {
    let url = URL(fileURLWithPath: "DevTools/TopShelfOriginals/\(original).png")
    guard let provider = CGDataProvider(url: url as CFURL),
          let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
        fatalError("Can't read \(url.path)")
    }
    let rep = NSBitmapImageRep(cgImage: vignette(image))
    let out = URL(fileURLWithPath: "\(brand)/\(target)")
    try! rep.representation(using: .png, properties: [:])!.write(to: out)
    print("wrote", out.lastPathComponent, image.width, "x", image.height)
}
