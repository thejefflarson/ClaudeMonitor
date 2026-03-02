#!/usr/bin/env swift
import AppKit

let _ = NSApplication.shared

let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext
ctx.setShouldAntialias(true)

// Dark rounded background
let corner: CGFloat = size * 0.22
let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                  cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.addPath(path)
ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1))
ctx.fillPath()

// "$" symbol
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: size * 0.57, weight: .semibold),
    .foregroundColor: NSColor(white: 0.93, alpha: 1.0)
]
let str = NSAttributedString(string: "$", attributes: attrs)
let strSize = str.size()
str.draw(at: NSPoint(x: (size - strSize.width) / 2,
                     y: (size - strSize.height) / 2 + size * 0.03))

// Amber activity dot (bottom-right)
let dot: CGFloat = size * 0.115
ctx.setFillColor(CGColor(red: 1.0, green: 0.62, blue: 0.18, alpha: 1.0))
ctx.fillEllipse(in: CGRect(x: size * 0.72, y: size * 0.13, width: dot, height: dot))

image.unlockFocus()

if let tiff = image.tiffRepresentation,
   let bmp = NSBitmapImageRep(data: tiff),
   let png = bmp.representation(using: .png, properties: [:]) {
    try! png.write(to: URL(fileURLWithPath: "icon_source.png"))
    print("Saved icon_source.png")
}
