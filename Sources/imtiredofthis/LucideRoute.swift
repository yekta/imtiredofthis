import AppKit

/// Lucide's `route` icon (ISC licensed), drawn as a template image for the menu bar.
enum LucideRoute {
    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let transform = NSAffineTransform()
            transform.scale(by: size / 24)
            transform.concat()

            NSColor.black.setStroke()
            let start = NSBezierPath(ovalIn: NSRect(x: 3, y: 16, width: 6, height: 6))
            let end = NSBezierPath(ovalIn: NSRect(x: 15, y: 2, width: 6, height: 6))
            let road = NSBezierPath()
            road.move(to: NSPoint(x: 9, y: 19))
            road.line(to: NSPoint(x: 17.5, y: 19))
            road.appendArc(withCenter: NSPoint(x: 17.5, y: 15.5), radius: 3.5, startAngle: 90, endAngle: -90, clockwise: true)
            road.line(to: NSPoint(x: 6.5, y: 12))
            road.appendArc(withCenter: NSPoint(x: 6.5, y: 8.5), radius: 3.5, startAngle: 90, endAngle: 270, clockwise: false)
            road.line(to: NSPoint(x: 15, y: 5))
            for path in [start, end, road] {
                path.lineWidth = 2
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "imtiredofthis"
        return image
    }
}
