// make-sketch-assets.swift — handgekritzelte Assets fuer CallNotes, zweisprachig:
//   assets/banner.png / banner.de.png              (1280x640)
//   assets/how-it-works.png / how-it-works.de.png  (760x1150)
// Nutzung: swift assets/make-sketch-assets.swift
import AppKit

let assetsDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

let ink = NSColor(calibratedWhite: 0.96, alpha: 1)
let indigo = NSColor(calibratedRed: 0.55, green: 0.50, blue: 1.00, alpha: 1)
let violet = NSColor(calibratedRed: 0.80, green: 0.45, blue: 0.98, alpha: 1)
let green = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.55, alpha: 1)
let bgDark = NSColor(calibratedRed: 0.055, green: 0.055, blue: 0.10, alpha: 1)

func rnd(_ a: Double, _ b: Double) -> CGFloat { CGFloat(a + drand48() * (b - a)) }

func handFont(_ size: CGFloat, bold: Bool = false) -> NSFont {
    for name in ["BradleyHandITCTT-Bold", "Bradley Hand", "MarkerFelt-Wide", "Marker Felt", "ChalkboardSE-Regular", "Chalkboard SE"] {
        if let f = NSFont(name: name, size: size) { return f }
    }
    return NSFont.systemFont(ofSize: size, weight: .medium)
}

func jitterPoints(_ a: NSPoint, _ b: NSPoint, amp: Double = 2.2) -> [NSPoint] {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = max(hypot(dx, dy), 1)
    let steps = max(Int(len / 22), 2)
    var pts: [NSPoint] = [a]
    for i in 1..<steps {
        let t = CGFloat(i) / CGFloat(steps)
        pts.append(NSPoint(x: a.x + dx * t + rnd(-amp, amp), y: a.y + dy * t + rnd(-amp, amp)))
    }
    pts.append(NSPoint(x: b.x + rnd(-1, 1), y: b.y + rnd(-1, 1)))
    return pts
}

func strokePath(_ pts: [NSPoint], color: NSColor, width: CGFloat) {
    let p = NSBezierPath()
    p.lineWidth = width
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    p.move(to: pts[0])
    for pt in pts.dropFirst() { p.line(to: pt) }
    color.setStroke()
    p.stroke()
}

func sketchLine(_ a: NSPoint, _ b: NSPoint, color: NSColor, width: CGFloat = 2.4, amp: Double = 2.2) {
    strokePath(jitterPoints(a, b, amp: amp), color: color, width: width)
}

func sketchRect(_ r: NSRect, color: NSColor, fill: NSColor? = nil, width: CGFloat = 2.6) {
    if let f = fill {
        f.setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
    let o: CGFloat = 5
    let edges: [(NSPoint, NSPoint)] = [
        (NSPoint(x: r.minX - o, y: r.maxY), NSPoint(x: r.maxX + o, y: r.maxY)),
        (NSPoint(x: r.maxX, y: r.maxY + o), NSPoint(x: r.maxX, y: r.minY - o)),
        (NSPoint(x: r.maxX + o, y: r.minY), NSPoint(x: r.minX - o, y: r.minY)),
        (NSPoint(x: r.minX, y: r.minY - o), NSPoint(x: r.minX, y: r.maxY + o)),
    ]
    for (a, b) in edges {
        sketchLine(a, b, color: color, width: width)
        sketchLine(a, b, color: color.withAlphaComponent(0.35), width: width * 0.7, amp: 3.2)
    }
}

func sketchArrow(_ a: NSPoint, _ b: NSPoint, color: NSColor, width: CGFloat = 2.4) {
    let mid = NSPoint(x: (a.x + b.x) / 2 + rnd(-7, 7), y: (a.y + b.y) / 2 + rnd(-3, 3))
    strokePath(jitterPoints(a, mid) + jitterPoints(mid, b).dropFirst(), color: color, width: width)
    let ang = atan2(b.y - a.y, b.x - a.x)
    for da in [2.55, -2.55] {
        let tip = NSPoint(x: b.x + 13 * cos(ang + CGFloat(da)), y: b.y + 13 * sin(ang + CGFloat(da)))
        sketchLine(b, tip, color: color, width: width)
    }
}

func handText(_ s: String, center: NSPoint, size: CGFloat, color: NSColor, rotation: CGFloat = 0, bold: Bool = false) {
    let attrs: [NSAttributedString.Key: Any] = [.font: handFont(size, bold: bold), .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: attrs)
    let sz = str.size()
    NSGraphicsContext.current?.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: center.x, yBy: center.y)
    t.rotate(byDegrees: rotation)
    t.concat()
    str.draw(at: NSPoint(x: -sz.width / 2, y: -sz.height / 2))
    NSGraphicsContext.current?.restoreGraphicsState()
}

func savePNG(_ image: NSImage, to url: URL, w: Int, h: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func sketchPhone(center c: NSPoint, scale s: CGFloat, color: NSColor) {
    let bow = NSBezierPath()
    bow.lineWidth = 12 * s
    bow.lineCapStyle = .round
    var pts: [NSPoint] = []
    for i in 0...20 {
        let t = CGFloat(i) / 20
        let ang = CGFloat.pi * (0.15 + 0.7 * t)
        pts.append(NSPoint(x: c.x + cos(ang) * 52 * s + rnd(-1.5, 1.5),
                           y: c.y + sin(ang) * 44 * s + rnd(-1.5, 1.5)))
    }
    bow.move(to: pts[0])
    for p in pts.dropFirst() { bow.line(to: p) }
    color.setStroke()
    bow.stroke()
    for end in [pts.first!, pts.last!] {
        let r: CGFloat = 19 * s
        let circle = NSBezierPath(ovalIn: NSRect(x: end.x - r + rnd(-1, 1), y: end.y - r + rnd(-1, 1), width: r * 2, height: r * 2))
        circle.lineWidth = 5 * s
        color.setFill()
        circle.fill()
    }
    for (i, rad) in [26, 40, 54].enumerated() {
        let w = NSBezierPath()
        w.lineWidth = 3.2 * s
        w.lineCapStyle = .round
        var wp: [NSPoint] = []
        for j in 0...8 {
            let t = CGFloat(j) / 8
            let ang = CGFloat.pi * (0.12 + 0.28 * t)
            wp.append(NSPoint(x: c.x + 46 * s + cos(ang) * CGFloat(rad) * s + rnd(-1.2, 1.2),
                              y: c.y + 20 * s + sin(ang) * CGFloat(rad) * s + rnd(-1.2, 1.2)))
        }
        w.move(to: wp[0])
        for p in wp.dropFirst() { w.line(to: p) }
        color.withAlphaComponent(1.0 - CGFloat(i) * 0.28).setStroke()
        w.stroke()
    }
}

func sketchWaveform(in rect: NSRect, color: NSColor, bars: Int) {
    let step = rect.width / CGFloat(bars)
    for i in 0..<bars {
        let x = rect.minX + CGFloat(i) * step + rnd(-1.5, 1.5)
        let h = rect.height * rnd(0.18, 1.0)
        let y = rect.midY - h / 2 + rnd(-2, 2)
        sketchLine(NSPoint(x: x, y: y), NSPoint(x: x, y: y + h),
                   color: color.withAlphaComponent(rnd(0.55, 1.0)), width: rnd(3.4, 4.6), amp: 1.1)
    }
}

// ---------- Texte je Sprache ----------

struct BannerTexts {
    let tagline: String
    let subline: String
    let you: String
    let caller: String
    let noteTitle: String
}

struct DiagramTexts {
    let detected: (String, String)
    let mic: (String, String)
    let caller: (String, String)
    let tracksNote: String
    let whisper: (String, String)
    let diarize: (String, String)
    let whoNote: String
    let ai: (String, String)
    let choiceNote: String
    let note: (String, String)
    let targets: [String]
    let footer: String
}

let bannerEN = BannerTexts(tagline: "calls become notes. automatically.",
                           subline: "on-device transcription · speaker separation · your choice of AI",
                           you: "you", caller: "caller", noteTitle: "call w/ Anna")
let bannerDE = BannerTexts(tagline: "aus Anrufen werden Notizen. automatisch.",
                           subline: "Transkription am Gerät · Sprecher-Trennung · KI deiner Wahl",
                           you: "du", caller: "Anrufer", noteTitle: "Anruf m. Anna")

let diagramEN = DiagramTexts(
    detected: ("call detected", "FaceTime · WhatsApp · Zoom · Teams"),
    mic: ("your mic", "own track"),
    caller: ("caller audio", "process tap — no drivers"),
    tracksNote: "2 separate tracks!",
    whisper: ("whisper transcription", "on-device (or Groq API)"),
    diarize: ("speaker separation", "sherpa-onnx · 100% local"),
    whoNote: "who said what?",
    ai: ("AI summary", "Claude · any OpenAI API · Ollama · none"),
    choiceNote: "your choice!",
    note: ("markdown note", "summary · to-dos · full transcript"),
    targets: ["Obsidian", "Apple Notes", "Nextcloud", "Notion", "external drive"],
    footer: "~1 minute after you hang up. no cloud required.")

let diagramDE = DiagramTexts(
    detected: ("Anruf erkannt", "FaceTime · WhatsApp · Zoom · Teams"),
    mic: ("dein Mikro", "eigene Spur"),
    caller: ("Anrufer-Audio", "Process Tap — keine Treiber"),
    tracksNote: "2 getrennte Spuren!",
    whisper: ("Whisper-Transkription", "am Gerät (oder Groq-API)"),
    diarize: ("Sprecher-Trennung", "sherpa-onnx · 100% lokal"),
    whoNote: "wer sagt was?",
    ai: ("KI-Zusammenfassung", "Claude · jede OpenAI-API · Ollama · keine"),
    choiceNote: "deine Wahl!",
    note: ("Markdown-Notiz", "Kurzfassung · To-dos · Transkript"),
    targets: ["Obsidian", "Apple Notes", "Nextcloud", "Notion", "externe Platte"],
    footer: "~1 Minute nach dem Auflegen. ganz ohne Cloud.")

// ---------- Banner ----------

func drawBanner(_ t: BannerTexts) -> NSImage {
    srand48(4711) // identisches Gekritzel in beiden Sprachen
    let bw: CGFloat = 1280, bh: CGFloat = 640
    return NSImage(size: NSSize(width: bw, height: bh), flipped: false) { _ in
        bgDark.setFill()
        NSRect(x: 0, y: 0, width: bw, height: bh).fill()

        sketchPhone(center: NSPoint(x: 175, y: 400), scale: 2.0, color: ink)

        let note = NSRect(x: 1075, y: 400, width: 150, height: 170)
        sketchRect(note, color: ink.withAlphaComponent(0.9), fill: ink.withAlphaComponent(0.06), width: 2.6)
        handText(t.noteTitle, center: NSPoint(x: note.midX, y: note.maxY - 28), size: 20, color: violet, rotation: -2)
        for (i, w) in [CGFloat(96), 78, 104].enumerated() {
            let y = note.maxY - 58 - CGFloat(i) * 22
            sketchLine(NSPoint(x: note.minX + 18, y: y), NSPoint(x: note.minX + 18 + w, y: y - rnd(-2, 2)),
                       color: ink.withAlphaComponent(0.45), width: 2.6, amp: 1.6)
        }
        sketchLine(NSPoint(x: note.minX + 20, y: note.minY + 28), NSPoint(x: note.minX + 28, y: note.minY + 18), color: green, width: 3)
        sketchLine(NSPoint(x: note.minX + 28, y: note.minY + 18), NSPoint(x: note.minX + 44, y: note.minY + 40), color: green, width: 3)
        sketchLine(NSPoint(x: note.minX + 54, y: note.minY + 28), NSPoint(x: note.minX + 118, y: note.minY + 26), color: ink.withAlphaComponent(0.45), width: 2.6, amp: 1.6)
        sketchArrow(NSPoint(x: 300, y: 545), NSPoint(x: 1058, y: 560), color: ink.withAlphaComponent(0.35), width: 2.6)

        handText("CallNotes", center: NSPoint(x: 735, y: 445), size: 130, color: ink, rotation: -1.5, bold: true)
        sketchLine(NSPoint(x: 437, y: 372), NSPoint(x: 1037, y: 362), color: violet, width: 5, amp: 3.5)
        sketchLine(NSPoint(x: 445, y: 360), NSPoint(x: 1005, y: 352), color: violet.withAlphaComponent(0.5), width: 3.4, amp: 4)

        handText(t.tagline, center: NSPoint(x: 737, y: 305), size: 44, color: violet, rotation: -1)
        handText(t.subline, center: NSPoint(x: 725, y: 245), size: 27, color: ink.withAlphaComponent(0.62), rotation: -0.6)

        handText(t.you, center: NSPoint(x: 118, y: 150), size: 26, color: indigo, rotation: -3)
        sketchWaveform(in: NSRect(x: 170, y: 118, width: 1000, height: 60), color: indigo, bars: 46)
        handText(t.caller, center: NSPoint(x: 112, y: 72), size: 26, color: violet, rotation: -2)
        sketchWaveform(in: NSRect(x: 170, y: 42, width: 1000, height: 56), color: violet, bars: 46)
        return true
    }
}

// ---------- How it works ----------

func drawDiagram(_ t: DiagramTexts) -> NSImage {
    srand48(1234)
    let dw: CGFloat = 760, dh: CGFloat = 1150
    return NSImage(size: NSSize(width: dw, height: dh), flipped: false) { _ in
        bgDark.setFill()
        NSRect(x: 0, y: 0, width: dw, height: dh).fill()

        func box(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat,
                 _ title: String, _ sub: String, _ color: NSColor, rot: CGFloat = 0) -> NSRect {
            let r = NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            sketchRect(r, color: color, fill: color.withAlphaComponent(0.10))
            handText(title, center: NSPoint(x: cx, y: cy + (sub.isEmpty ? 0 : 13)), size: 27, color: ink, rotation: rot, bold: true)
            if !sub.isEmpty {
                handText(sub, center: NSPoint(x: cx, y: cy - 15), size: 19, color: ink.withAlphaComponent(0.6), rotation: rot)
            }
            return r
        }

        let cx = dw / 2

        let b1 = box(cx, 1080, 400, 84, t.detected.0, t.detected.1, indigo, rot: -0.8)

        let b2a = box(cx - 172, 940, 300, 80, t.mic.0, t.mic.1, indigo, rot: -1)
        let b2b = box(cx + 172, 940, 300, 80, t.caller.0, t.caller.1, violet, rot: 0.8)
        sketchArrow(NSPoint(x: b1.midX - 60, y: b1.minY - 4), NSPoint(x: b2a.midX + 30, y: b2a.maxY + 6), color: ink)
        sketchArrow(NSPoint(x: b1.midX + 60, y: b1.minY - 4), NSPoint(x: b2b.midX - 30, y: b2b.maxY + 6), color: ink)
        handText(t.tracksNote, center: NSPoint(x: dw - 96, y: 1013), size: 20, color: green, rotation: -7)

        let b3 = box(cx, 800, 430, 84, t.whisper.0, t.whisper.1, violet, rot: -0.5)
        sketchArrow(NSPoint(x: b2a.midX + 20, y: b2a.minY - 4), NSPoint(x: b3.midX - 60, y: b3.maxY + 6), color: ink)
        sketchArrow(NSPoint(x: b2b.midX - 20, y: b2b.minY - 4), NSPoint(x: b3.midX + 60, y: b3.maxY + 6), color: ink)

        let b4 = box(cx, 662, 430, 84, t.diarize.0, t.diarize.1, violet, rot: 0.6)
        sketchArrow(NSPoint(x: b3.midX, y: b3.minY - 4), NSPoint(x: b4.midX, y: b4.maxY + 6), color: ink)
        handText(t.whoNote, center: NSPoint(x: 92, y: 731), size: 20, color: ink.withAlphaComponent(0.5), rotation: 6)

        let b5 = box(cx, 524, 430, 84, t.ai.0, t.ai.1, indigo, rot: -0.7)
        sketchArrow(NSPoint(x: b4.midX, y: b4.minY - 4), NSPoint(x: b5.midX, y: b5.maxY + 6), color: ink)
        handText(t.choiceNote, center: NSPoint(x: dw - 92, y: 593), size: 20, color: green, rotation: -6)

        let b6 = box(cx, 376, 450, 96, t.note.0, t.note.1, green, rot: 0.5)
        sketchArrow(NSPoint(x: b5.midX, y: b5.minY - 4), NSPoint(x: b6.midX, y: b6.maxY + 6), color: ink)
        sketchWaveform(in: NSRect(x: b6.maxX + 14, y: 352, width: 60, height: 44), color: green, bars: 6)

        let tw: CGFloat = 132
        let total = tw * CGFloat(t.targets.count) + 12 * CGFloat(t.targets.count - 1)
        var tx = cx - total / 2 + tw / 2
        for tgt in t.targets {
            let r = NSRect(x: tx - tw / 2, y: 196, width: tw, height: 62)
            sketchRect(r, color: ink.withAlphaComponent(0.65), fill: ink.withAlphaComponent(0.05), width: 2)
            handText(tgt, center: NSPoint(x: tx, y: 227), size: 18.5, color: ink.withAlphaComponent(0.85), rotation: rnd(-2, 2))
            sketchArrow(NSPoint(x: b6.midX + (tx - b6.midX) * 0.28, y: b6.minY - 6), NSPoint(x: tx, y: r.maxY + 8), color: ink.withAlphaComponent(0.55), width: 2)
            tx += tw + 12
        }

        handText(t.footer, center: NSPoint(x: cx, y: 128), size: 26, color: violet, rotation: -1.2)
        sketchLine(NSPoint(x: cx - 250, y: 100), NSPoint(x: cx + 250, y: 94), color: violet.withAlphaComponent(0.5), width: 3, amp: 3.5)
        return true
    }
}

// ---------- generieren ----------
savePNG(drawBanner(bannerEN), to: assetsDir.appendingPathComponent("banner.png"), w: 1280, h: 640)
savePNG(drawBanner(bannerDE), to: assetsDir.appendingPathComponent("banner.de.png"), w: 1280, h: 640)
savePNG(drawDiagram(diagramEN), to: assetsDir.appendingPathComponent("how-it-works.png"), w: 760, h: 1150)
savePNG(drawDiagram(diagramDE), to: assetsDir.appendingPathComponent("how-it-works.de.png"), w: 760, h: 1150)
print("OK: banner.png + banner.de.png + how-it-works.png + how-it-works.de.png")

// ---------- Screenshot-Compose (assets/screenshots.png) ----------

func drawRotatedShot(_ url: URL, center: NSPoint, height: CGFloat, rotation: CGFloat) {
    guard let img = NSImage(contentsOf: url) else { return }
    let scale = height / img.size.height
    let w = img.size.width * scale
    NSGraphicsContext.current?.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: center.x, yBy: center.y)
    t.rotate(byDegrees: rotation)
    t.concat()
    let sh = NSShadow()
    sh.shadowBlurRadius = 20
    sh.shadowColor = NSColor.black.withAlphaComponent(0.65)
    sh.shadowOffset = NSSize(width: 0, height: -7)
    sh.set()
    img.draw(in: NSRect(x: -w / 2, y: -height / 2, width: w, height: height))
    NSShadow().set()
    sketchRect(NSRect(x: -w / 2, y: -height / 2, width: w, height: height),
               color: ink.withAlphaComponent(0.8), width: 2.2)
    NSGraphicsContext.current?.restoreGraphicsState()
}

struct ShotLabels {
    let live: String
    let match: String
    let yours: String
}

func drawShotsCompose(suffix: String, labels: ShotLabels, out: String) {
    let shotsDir = assetsDir.appendingPathComponent("shots")
    let cw: CGFloat = 1280, ch: CGFloat = 880
    srand48(99)
    let img = NSImage(size: NSSize(width: cw, height: ch), flipped: false) { _ in
        bgDark.setFill()
        NSRect(x: 0, y: 0, width: cw, height: ch).fill()

        drawRotatedShot(shotsDir.appendingPathComponent("shot-settings\(suffix).png"),
                        center: NSPoint(x: 990, y: 420), height: 660, rotation: 2.2)
        drawRotatedShot(shotsDir.appendingPathComponent("shot-call\(suffix).png"),
                        center: NSPoint(x: 300, y: 430), height: 640, rotation: -2.4)
        drawRotatedShot(shotsDir.appendingPathComponent("shot-pending\(suffix).png"),
                        center: NSPoint(x: 648, y: 300), height: 430, rotation: -1.2)

        handText(labels.live, center: NSPoint(x: 250, y: 828), size: 27, color: indigo, rotation: -2)
        sketchArrow(NSPoint(x: 300, y: 806), NSPoint(x: 320, y: 700), color: indigo, width: 2.6)

        handText(labels.match, center: NSPoint(x: 655, y: 610), size: 26, color: green, rotation: 1.5)
        sketchArrow(NSPoint(x: 655, y: 588), NSPoint(x: 650, y: 500), color: green, width: 2.6)

        handText(labels.yours, center: NSPoint(x: 965, y: 830), size: 26, color: violet, rotation: 1.5)
        sketchArrow(NSPoint(x: 990, y: 808), NSPoint(x: 985, y: 762), color: violet, width: 2.6)
        return true
    }
    savePNG(img, to: assetsDir.appendingPathComponent(out), w: 1280, h: 880)
    print("OK: assets/\(out)")
}

drawShotsCompose(suffix: "",
                 labels: ShotLabels(live: "live level tracks while you talk",
                                    match: "match voices to names",
                                    yours: "your AI · your storage · your language"),
                 out: "screenshots.png")
drawShotsCompose(suffix: ".de",
                 labels: ShotLabels(live: "Live-Pegel, während du sprichst",
                                    match: "Stimmen den Namen zuordnen",
                                    yours: "deine KI · dein Speicher · deine Sprache"),
                 out: "screenshots.de.png")
