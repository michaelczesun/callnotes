// make-assets.swift — erzeugt App-Icon (.icns) und GitHub-Banner fuer CallNotes.
// Nutzung: swift assets/make-assets.swift   (schreibt nach assets/)
import AppKit

let assetsDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let grad1 = NSColor(calibratedRed: 0.42, green: 0.36, blue: 1.00, alpha: 1)   // Indigo
let grad2 = NSColor(calibratedRed: 0.75, green: 0.35, blue: 0.95, alpha: 1)   // Violett
let bgDark = NSColor(calibratedRed: 0.055, green: 0.055, blue: 0.10, alpha: 1)

func savePNG(_ image: NSImage, to url: URL, size: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func savePNGWide(_ image: NSImage, to url: URL, w: Int, h: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
               from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func symbolImage(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return base.withSymbolConfiguration(cfg)
}

func drawWaveform(in rect: NSRect, bars: [CGFloat], color: NSColor, barWidth: CGFloat, gap: CGFloat) {
    var x = rect.minX
    let midY = rect.midY
    for b in bars {
        let h = rect.height * b
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: midY - h / 2, width: barWidth, height: h),
                               xRadius: barWidth / 2, yRadius: barWidth / 2)
        color.setFill()
        bar.fill()
        x += barWidth + gap
        if x > rect.maxX { break }
    }
}

// ---------- App-Icon (1024, Squircle + Gradient + Symbol + Waveform) ----------
let iconSize: CGFloat = 1024
let icon = NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { _ in
    // macOS-Squircle (Naeherung ueber grosszuegig gerundetes Rechteck, mit Rand-Inset)
    let inset: CGFloat = iconSize * 0.055
    let rect = NSRect(x: inset, y: inset, width: iconSize - inset * 2, height: iconSize - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.235, yRadius: rect.width * 0.235)
    NSGradient(starting: grad1, ending: grad2)!.draw(in: squircle, angle: -55)

    // dezenter Glanz oben
    let gloss = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2),
                             xRadius: rect.width * 0.235, yRadius: rect.width * 0.235)
    NSColor.white.withAlphaComponent(0.07).setFill()
    gloss.fill()

    // Telefon + Waveform
    if let sym = symbolImage("phone.and.waveform.fill", pointSize: 430, color: .white) ?? symbolImage("phone.fill", pointSize: 430, color: .white) {
        let s = sym.size
        sym.draw(in: NSRect(x: (iconSize - s.width) / 2, y: (iconSize - s.height) / 2 + 30,
                            width: s.width, height: s.height))
    }
    // Waveform-Zeile unten
    let bars: [CGFloat] = [0.25, 0.55, 0.9, 0.5, 0.75, 0.35, 0.65, 0.95, 0.45, 0.7, 0.3, 0.55]
    let waveW: CGFloat = 460
    drawWaveform(in: NSRect(x: (iconSize - waveW) / 2, y: 178, width: waveW, height: 92),
                 bars: bars, color: NSColor.white.withAlphaComponent(0.85), barWidth: 22, gap: 18)
    return true
}

// PNGs + iconset
let iconPNG = assetsDir.appendingPathComponent("icon-1024.png")
savePNG(icon, to: iconPNG, size: 1024)
savePNG(icon, to: assetsDir.appendingPathComponent("icon-256.png"), size: 256)

let iconsetDir = assetsDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try! FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    savePNG(icon, to: iconsetDir.appendingPathComponent("\(name).png"), size: px)
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir.path, "-o", assetsDir.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetDir)
print("OK: assets/AppIcon.icns + icon-1024.png + icon-256.png")

// ---------- GitHub-Banner (1280x640, auch als Social Preview) ----------
let bw: CGFloat = 1280, bh: CGFloat = 640
let banner = NSImage(size: NSSize(width: bw, height: bh), flipped: false) { _ in
    bgDark.setFill()
    NSRect(x: 0, y: 0, width: bw, height: bh).fill()

    // sanfter Farbschein oben rechts
    let glow = NSGradient(starting: grad2.withAlphaComponent(0.22), ending: .clear)!
    glow.draw(fromCenter: NSPoint(x: bw * 0.82, y: bh * 0.8), radius: 0,
              toCenter: NSPoint(x: bw * 0.82, y: bh * 0.8), radius: 520, options: [])

    // Mini-Icon links
    let iconRect = NSRect(x: 96, y: bh - 96 - 148, width: 148, height: 148)
    let sq = NSBezierPath(roundedRect: iconRect, xRadius: 34, yRadius: 34)
    NSGradient(starting: grad1, ending: grad2)!.draw(in: sq, angle: -55)
    if let sym = symbolImage("phone.and.waveform.fill", pointSize: 64, color: .white) ?? symbolImage("phone.fill", pointSize: 64, color: .white) {
        let s = sym.size
        sym.draw(in: NSRect(x: iconRect.midX - s.width / 2, y: iconRect.midY - s.height / 2 + 3,
                            width: s.width, height: s.height))
    }

    // Titel + Tagline
    let title = "CallNotes" as NSString
    title.draw(at: NSPoint(x: 280, y: bh - 118 - 96),
               withAttributes: [.font: NSFont.systemFont(ofSize: 96, weight: .bold),
                                .foregroundColor: NSColor.white])
    let tag = "Calls become notes. Automatically." as NSString
    tag.draw(at: NSPoint(x: 284, y: bh - 118 - 96 - 52),
             withAttributes: [.font: NSFont.systemFont(ofSize: 34, weight: .medium),
                              .foregroundColor: grad2])
    let sub = "On-device transcription · speaker separation · AI summaries · macOS menu bar" as NSString
    sub.draw(at: NSPoint(x: 285, y: bh - 118 - 96 - 104),
             withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .regular),
                              .foregroundColor: NSColor.white.withAlphaComponent(0.62)])

    // zwei Waveform-Spuren unten (du + Gegenseite)
    let bars1: [CGFloat] = (0..<44).map { i in 0.2 + 0.8 * abs(sin(Double(i) * 0.55 + 0.9)) }.map { CGFloat($0) }
    let bars2: [CGFloat] = (0..<44).map { i in 0.2 + 0.8 * abs(sin(Double(i) * 0.42 + 2.2)) }.map { CGFloat($0) }
    drawWaveform(in: NSRect(x: 96, y: 128, width: bw - 192, height: 56),
                 bars: bars1, color: grad1.withAlphaComponent(0.9), barWidth: 10, gap: 15)
    drawWaveform(in: NSRect(x: 96, y: 56, width: bw - 192, height: 56),
                 bars: bars2, color: grad2.withAlphaComponent(0.85), barWidth: 10, gap: 15)
    return true
}
savePNGWide(banner, to: assetsDir.appendingPathComponent("banner.png"), w: 1280, h: 640)
print("OK: assets/banner.png (1280x640 — auch als GitHub Social Preview nutzbar)")
