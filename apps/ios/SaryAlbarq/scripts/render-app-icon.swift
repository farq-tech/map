#!/usr/bin/env swift
// Renders the app icon (1024×1024, opaque, no alpha — App Store rule) with Core
// Graphics: a night sky in the Dark Sand palette, a headlight beam over two dunes
// and a forward arrow (the car's heading) on the ridge. Original art, drawn here;
// the in-app mark (`SaryMarkDrawing`) uses the same geometry.
//   swift scripts/render-app-icon.swift Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let S = 1024
let w = CGFloat(S), h = CGFloat(S)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Core Graphics is y-up; the drawing below is written y-down like SwiftUI.
ctx.translateBy(x: 0, y: h)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }
func linear(_ path: CGPath, _ colors: [CGColor], _ a: CGPoint, _ b: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// Night sky
linear(CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil), [rgb(0x1A1612), rgb(0x2B2118)], P(0, 0), P(0, 1))
// A few stars
for (x, y, r) in [(0.18, 0.14, 5.0), (0.34, 0.08, 3.5), (0.80, 0.12, 4.5), (0.90, 0.30, 3.0), (0.70, 0.22, 2.5), (0.46, 0.18, 2.5)] as [(CGFloat, CGFloat, CGFloat)] {
    ctx.setFillColor(rgb(0xF4EFE6, 0.75))
    ctx.fillEllipse(in: CGRect(x: w * x - r, y: h * y - r, width: r * 2, height: r * 2))
}
// Headlight beam
let beam = CGMutablePath()
beam.move(to: P(0.60, 0.60)); beam.addLine(to: P(0.02, 0.20)); beam.addLine(to: P(0.10, 0.48)); beam.closeSubpath()
linear(beam, [rgb(0xF2C36B, 0.85), rgb(0xF2C36B, 0)], P(0.6, 0.6), P(0.05, 0.3))
// Back dune
let back = CGMutablePath()
back.move(to: P(0, 0.70))
back.addCurve(to: P(1, 0.58), control1: P(0.35, 0.50), control2: P(0.65, 0.72))
back.addLine(to: P(1, 1)); back.addLine(to: P(0, 1)); back.closeSubpath()
ctx.addPath(back); ctx.setFillColor(rgb(0xB8661F)); ctx.fillPath()
// Front dune with a sharp ridge
let front = CGMutablePath()
front.move(to: P(0, 0.86))
front.addCurve(to: P(0.62, 0.66), control1: P(0.25, 0.80), control2: P(0.45, 0.66))
front.addCurve(to: P(1, 0.80), control1: P(0.78, 0.66), control2: P(0.9, 0.74))
front.addLine(to: P(1, 1)); front.addLine(to: P(0, 1)); front.closeSubpath()
linear(front, [rgb(0xE8842C), rgb(0xC96F22)], P(0.6, 0.66), P(0.6, 1))
// Wind ripples on the front dune
ctx.setStrokeColor(rgb(0xF2C36B, 0.35)); ctx.setLineWidth(6); ctx.setLineCap(.round)
for (y, x0, x1) in [(0.84, 0.12, 0.42), (0.90, 0.30, 0.66), (0.80, 0.66, 0.92)] as [(CGFloat, CGFloat, CGFloat)] {
    let r = CGMutablePath(); r.move(to: P(x0, y)); r.addQuadCurve(to: P(x1, y - 0.02), control: P((x0 + x1) / 2, y - 0.045)); ctx.addPath(r); ctx.strokePath()
}
// Forward arrow on the ridge
let c = P(0.62, 0.47), r = w * 0.17
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: c.x - r * 0.95, y: c.y + r * 0.55))
arrow.addLine(to: CGPoint(x: c.x + r * 0.05, y: c.y - r * 0.95))
arrow.addLine(to: CGPoint(x: c.x + r * 0.95, y: c.y + r * 0.55))
arrow.addLine(to: CGPoint(x: c.x + r * 0.05, y: c.y + r * 0.12))
arrow.closeSubpath()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: rgb(0x000000, 0.35))
ctx.addPath(arrow); ctx.setFillColor(rgb(0xF4EFE6)); ctx.fillPath()
// Headlight
ctx.setShadow(offset: .zero, blur: 40, color: rgb(0xFFE3A3, 0.9))
ctx.setFillColor(rgb(0xFFE3A3))
ctx.fillEllipse(in: CGRect(x: w * 0.555, y: h * 0.555, width: w * 0.09, height: w * 0.09))

let img = ctx.makeImage()!
let url = URL(fileURLWithPath: out)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out)") }
print(out)
