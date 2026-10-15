import AppKit
import QuartzCore

/// Original vector geometry fitted to the ideal epitrochoid; not a manufacturer's CAD asset.
@MainActor
enum RotaryIcon {
    enum Part { case housing, rotor, shaft, complete }
    static let geometry: [String: [[Double]]] = {
        guard let url = Bundle.module.url(forResource: "RotaryGeometry", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: [[Double]]].self, from: data) else { return [:] }
        return value
    }()
    static func path(_ name: String) -> NSBezierPath {
        let p = NSBezierPath()
        for (i, xy) in (geometry[name] ?? []).enumerated() {
            let point = NSPoint(x: xy[0], y: xy[1])
            if i == 0 { p.move(to: point) } else { p.line(to: point) }
        }
        p.close(); return p
    }
    static func circle(_ radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: x-radius, y: y-radius, width: radius*2, height: radius*2))
    }
    static func gear(_ radius: CGFloat, teeth: Int) -> NSBezierPath {
        let p = NSBezierPath()
        for i in 0..<teeth*4 {
            let a = CGFloat(i) * .pi * 2 / CGFloat(teeth*4)
            let r = radius + (i % 4 == 0 || i % 4 == 3 ? -1.25 : 1.25)
            let point = NSPoint(x: cos(a)*r, y: sin(a)*r)
            if i == 0 { p.move(to: point) } else { p.line(to: point) }
        }
        p.close(); return p
    }
    static func image(size: CGFloat, part: Part = .complete, template: Bool = false, color: NSColor = .labelColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.translateBy(x: rect.midX, y: rect.midY)
            c.scaleBy(x: size / (template ? 240 : 264), y: size / (template ? 240 : 264))
            c.rotate(by: -.pi/2)
            let dark = NSColor(calibratedRed: 0.04, green: 0.12, blue: 0.14, alpha: 1)
            let green = NSColor(calibratedRed: 0.12, green: 0.26, blue: 0.23, alpha: 1)
            let metal = NSGradient(colors: [.init(white: 0.94, alpha: 1), .init(white: 0.62, alpha: 1), .init(white: 0.93, alpha: 1)])!
            func stroke(_ p: NSBezierPath, _ ink: NSColor, _ width: CGFloat) { ink.setStroke(); p.lineWidth = width; p.stroke() }
            func fill(_ p: NSBezierPath, _ ink: NSColor) { ink.setFill(); p.fill() }
            func clear(_ p: NSBezierPath) { c.saveGState(); c.setBlendMode(.clear); NSColor.black.setFill(); p.fill(); c.restoreGState() }
            if part == .housing || part == .complete {
                if template { stroke(path("housing"), color, 10) }
                else {
                    fill(path("outer"), dark); metal.draw(in: path("rim"), angle: 35)
                    for i in 0..<18 { fill(path("passage\(i)"), dark); stroke(path("passage\(i)"), .gray, 0.6) }
                    for xy in geometry["bolts"] ?? [] {
                        fill(circle(3.7, x: xy[0], y: xy[1]), dark)
                        metal.draw(in: circle(2.8, x: xy[0], y: xy[1]), angle: 45)
                    }
                    stroke(path("innerLip"), .white, 0.9)
                    NSGradient(colors: [.init(calibratedRed: 0.47, green: 0.62, blue: 0.68, alpha: 1), dark])!.draw(in: path("housing"), angle: 15)
                    stroke(path("housing"), green, 1.2)
                }
            }
            if part == .rotor || part == .complete {
                c.saveGState()
                if part == .complete { c.translateBy(x: 12, y: 0) }
                if template { fill(path("rotor"), color); clear(circle(39.3)) }
                else {
                    metal.draw(in: path("rotor"), angle: 130); stroke(path("rotor"), green, 1.1)
                    c.saveGState(); c.scaleBy(x: 0.955, y: 0.955); stroke(path("rotor"), green, 1); c.restoreGState()
                    fill(circle(44), green); stroke(circle(41.5), .lightGray, 1)
                    metal.draw(in: circle(40), angle: 40)
                    if part == .complete { fill(gear(36, teeth: 30), dark) } else { clear(gear(36, teeth: 30)) }
                    for i in 0..<3 {
                        let a = CGFloat(i)*2 * .pi/3
                        fill(circle(3, x: 79.8*cos(a), y: 79.8*sin(a)), green)
                        stroke(circle(3, x: 79.8*cos(a), y: 79.8*sin(a)), .lightGray, 0.6)
                    }
                }
                c.restoreGState()
            }
            if part == .shaft || part == .complete {
                if template { fill(circle(17.8), color) }
                else {
                    metal.draw(in: gear(24, teeth: 20), angle: 45)
                    fill(circle(20.3), dark); metal.draw(in: circle(17.8), angle: 115)
                    stroke(circle(17.8), .gray, 0.7)
                }
            }
            return true
        }
    }
}

/// Three cached textures; Core Animation moves only the rotor. No redraw timer or network polling.
@MainActor
final class RotaryIconView: NSView {
    let housingLayer = CALayer(), orbitLayer = CALayer(), rotorLayer = CALayer(), shaftLayer = CALayer()
    let template: Bool
    private(set) var phase: Double = 0
    private var startedAt: CFTimeInterval = CACurrentMediaTime()
    private var velocity: Double = 0
    private(set) var count: Int = 0
    override var allowsVibrancy: Bool { false }
    init(frame: NSRect, template: Bool) {
        self.template = template
        super.init(frame: frame); wantsLayer = true
        layer?.addSublayer(housingLayer); layer?.addSublayer(orbitLayer)
        orbitLayer.addSublayer(rotorLayer); layer?.addSublayer(shaftLayer)
        for l in [housingLayer, rotorLayer, shaftLayer] { l.contentsGravity = .resizeAspect }
        render(); layoutParts()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); render() }
    override func layout() { super.layout(); layoutParts() }
    private func render() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let size: CGFloat = template ? 60 : 108
            for (l, p) in [(housingLayer, RotaryIcon.Part.housing), (rotorLayer, .rotor), (shaftLayer, .shaft)] {
                let image = RotaryIcon.image(size: size, part: p, template: template, color: .labelColor)
                var rect = CGRect(x: 0, y: 0, width: size, height: size)
                l.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                l.contentsScale = 3
            }
        }
    }
    func currentPhase(at now: CFTimeInterval = CACurrentMediaTime()) -> Double { phase + (now-startedAt)*velocity }
    func configure(count: Int) {
        let desired = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : max(0, count)
        guard desired != self.count else { return }
        let now = CACurrentMediaTime()
        phase = currentPhase(at: now).truncatingRemainder(dividingBy: 6 * .pi)
        startedAt = now; self.count = desired
        velocity = desired > 0 ? -2 * .pi / MenuBarController.rotationDuration(conversations: desired) : 0
        layoutParts()
    }
    func pause() { configure(count: 0) }
    private func layoutParts() {
        let now = CACurrentMediaTime()
        phase = currentPhase(at: now).truncatingRemainder(dividingBy: 6 * .pi); startedAt = now
        let side = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let eccentricity = side * 12 / (template ? 240 : 264)
        func point(_ angle: Double) -> CGPoint { CGPoint(x: center.x + eccentricity*sin(angle), y: center.y - eccentricity*cos(angle)) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [housingLayer, orbitLayer, rotorLayer, shaftLayer] { l.bounds = CGRect(x: 0, y: 0, width: side, height: side) }
        housingLayer.position = center; shaftLayer.position = center
        orbitLayer.position = point(phase); rotorLayer.position = CGPoint(x: side/2, y: side/2)
        rotorLayer.transform = CATransform3DMakeRotation(phase/3, 0, 0, 1)
        orbitLayer.removeAllAnimations(); rotorLayer.removeAllAnimations()
        if count > 0 {
            let duration = MenuBarController.rotationDuration(conversations: count)
            let orbit = CAKeyframeAnimation(keyPath: "position")
            orbit.values = (0...120).map { NSValue(point: point(phase - Double($0)*2 * .pi/120)) }
            orbit.duration = duration; orbit.repeatCount = .infinity; orbit.calculationMode = .linear
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = phase/3; spin.toValue = phase/3 - 2 * .pi
            spin.duration = duration*3; spin.repeatCount = .infinity
            let begin = CACurrentMediaTime()
            orbit.beginTime = orbitLayer.convertTime(begin, from: nil); spin.beginTime = rotorLayer.convertTime(begin, from: nil)
            orbit.timingFunction = CAMediaTimingFunction(name: .linear); spin.timingFunction = CAMediaTimingFunction(name: .linear)
            orbitLayer.add(orbit, forKey: "rotaryOrbit"); rotorLayer.add(spin, forKey: "rotarySpin")
        }
        CATransaction.commit()
    }
}
