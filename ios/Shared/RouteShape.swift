import SwiftUI

/// Lucide's `route` icon (ISC licensed), on its 24 × 24 grid scaled to the frame.
struct RouteShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 3, y: 16, width: 6, height: 6))
        path.addEllipse(in: CGRect(x: 15, y: 2, width: 6, height: 6))
        path.move(to: CGPoint(x: 9, y: 19))
        path.addLine(to: CGPoint(x: 17.5, y: 19))
        path.addArc(center: CGPoint(x: 17.5, y: 15.5), radius: 3.5, startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
        path.addLine(to: CGPoint(x: 6.5, y: 12))
        path.addArc(center: CGPoint(x: 6.5, y: 8.5), radius: 3.5, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: 15, y: 5))
        let scale = min(rect.width, rect.height) / 24
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
    }
}

/// The route, stroked 2 points wide on the 24-point grid, as Lucide draws it.
struct RouteIcon: View {
    var body: some View {
        GeometryReader { geometry in
            RouteShape()
                .stroke(style: StrokeStyle(lineWidth: 2 * min(geometry.size.width, geometry.size.height) / 24, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Routey")
    }
}
