#!/usr/bin/env swift
// Generates a 1024x1024 app icon PNG for Lidless using CoreGraphics (headless-safe,
// no window server needed). The mark is an open eye — "Lidless" = the lid that
// never closes. Run: swift scripts/make_icon.swift Resources/icon_1024.png
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("ctx") }

let s = CGFloat(size)
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

// Rounded-rect background with a vertical gradient (deep indigo -> near black).
let inset: CGFloat = s * 0.06
let rect = CGRect(x: inset, y: inset, width: s - inset*2, height: s - inset*2)
let radius = (s - inset*2) * 0.235
let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(bgPath)
ctx.clip()
let cs = CGColorSpaceCreateDeviceRGB()
let grad = CGGradient(colorsSpace: cs,
                      colors: [rgb(40, 52, 110), rgb(14, 16, 34)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

let cx = s/2, cy = s/2

// Almond eye outline (two symmetric quadratic curves).
let halfW = s * 0.30
let halfH = s * 0.175
let eye = CGMutablePath()
eye.move(to: CGPoint(x: cx - halfW, y: cy))
eye.addQuadCurve(to: CGPoint(x: cx + halfW, y: cy), control: CGPoint(x: cx, y: cy + halfH*1.9))
eye.addQuadCurve(to: CGPoint(x: cx - halfW, y: cy), control: CGPoint(x: cx, y: cy - halfH*1.9))
eye.closeSubpath()

// White of the eye.
ctx.addPath(eye)
ctx.setFillColor(rgb(244, 247, 255))
ctx.fillPath()

// Iris (radial cyan -> blue), clipped to the eye shape.
ctx.saveGState()
ctx.addPath(eye)
ctx.clip()
let irisR = s * 0.135
let iris = CGGradient(colorsSpace: cs,
                      colors: [rgb(90, 220, 255), rgb(40, 120, 230)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(iris,
                       startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                       endCenter: CGPoint(x: cx, y: cy), endRadius: irisR,
                       options: [.drawsAfterEndLocation])
// keep only the iris disc
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: cx - irisR, y: cy - irisR, width: irisR*2, height: irisR*2))
ctx.clip()
ctx.drawRadialGradient(iris,
                       startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                       endCenter: CGPoint(x: cx, y: cy), endRadius: irisR,
                       options: [])
ctx.restoreGState()

// Pupil + highlight.
let pupilR = s * 0.062
ctx.setFillColor(rgb(10, 14, 30))
ctx.fillEllipse(in: CGRect(x: cx - pupilR, y: cy - pupilR, width: pupilR*2, height: pupilR*2))
let hl = s * 0.022
ctx.setFillColor(rgb(255, 255, 255, 0.9))
ctx.fillEllipse(in: CGRect(x: cx + pupilR*0.2, y: cy + pupilR*0.25, width: hl*2, height: hl*2))

guard let img = ctx.makeImage() else { fatalError("img") }
let url = URL(fileURLWithPath: out)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("dest") }
CGImageDestinationAddImage(dest, img, nil)
if CGImageDestinationFinalize(dest) {
    print("wrote \(out)")
} else {
    fatalError("write failed")
}
