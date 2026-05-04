import AppKit
import Foundation

/// Minimal SVG path parser — handles M, L, H, V, C, Z (absolute + relative).
/// Sufficient for the Claude logo path.
extension CGPath {
    static func from(svgPath: String) -> CGPath? {
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero

        let scanner = Scanner(string: svgPath)
        scanner.charactersToBeSkipped = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ","))

        var lastCommand: Character = "M"

        func scanNumber() -> CGFloat? {
            // Skip optional comma/whitespace
            _ = scanner.scanCharacters(from: CharacterSet(charactersIn: " ,\t\n\r"))
            if let d = scanner.scanDouble() { return CGFloat(d) }
            return nil
        }

        func scanPoint() -> CGPoint? {
            guard let x = scanNumber(), let y = scanNumber() else { return nil }
            return CGPoint(x: x, y: y)
        }

        while !scanner.isAtEnd {
            _ = scanner.scanCharacters(from: CharacterSet(charactersIn: " ,\t\n\r"))

            var cmd: Character = lastCommand
            let idx = scanner.currentIndex
            if let ch = scanner.string[idx...].first, ch.isLetter {
                cmd = ch
                scanner.currentIndex = scanner.string.index(after: idx)
            }

            let isRelative = cmd.isLowercase
            let upper = Character(String(cmd).uppercased())

            switch upper {
            case "M":
                guard let pt = scanPoint() else { break }
                let abs = isRelative ? CGPoint(x: current.x + pt.x, y: current.y + pt.y) : pt
                path.move(to: abs)
                current = abs
                start = abs
                // Subsequent coordinates after M are implicit L
                lastCommand = isRelative ? "l" : "L"
                continue

            case "L":
                guard let pt = scanPoint() else { break }
                let abs = isRelative ? CGPoint(x: current.x + pt.x, y: current.y + pt.y) : pt
                path.addLine(to: abs)
                current = abs

            case "H":
                guard let x = scanNumber() else { break }
                let absX = isRelative ? current.x + x : x
                path.addLine(to: CGPoint(x: absX, y: current.y))
                current.x = absX

            case "V":
                guard let y = scanNumber() else { break }
                let absY = isRelative ? current.y + y : y
                path.addLine(to: CGPoint(x: current.x, y: absY))
                current.y = absY

            case "C":
                guard let c1 = scanPoint(), let c2 = scanPoint(), let end = scanPoint() else { break }
                let absC1 = isRelative ? CGPoint(x: current.x + c1.x, y: current.y + c1.y) : c1
                let absC2 = isRelative ? CGPoint(x: current.x + c2.x, y: current.y + c2.y) : c2
                let absEnd = isRelative ? CGPoint(x: current.x + end.x, y: current.y + end.y) : end
                path.addCurve(to: absEnd, control1: absC1, control2: absC2)
                current = absEnd

            case "Z":
                path.closeSubpath()
                current = start

            default:
                break
            }

            lastCommand = cmd
        }

        return path
    }
}

extension NSBezierPath {
    convenience init(cgPath: CGPath) {
        self.init()
        cgPath.applyWithBlock { element in
            let pts = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                self.move(to: pts[0])
            case .addLineToPoint:
                self.line(to: pts[0])
            case .addCurveToPoint:
                self.curve(to: pts[2], controlPoint1: pts[0], controlPoint2: pts[1])
            case .addQuadCurveToPoint:
                // Approximate quad as cubic
                let cp1 = CGPoint(x: self.currentPoint.x + 2/3 * (pts[0].x - self.currentPoint.x),
                                  y: self.currentPoint.y + 2/3 * (pts[0].y - self.currentPoint.y))
                let cp2 = CGPoint(x: pts[1].x + 2/3 * (pts[0].x - pts[1].x),
                                  y: pts[1].y + 2/3 * (pts[0].y - pts[1].y))
                self.curve(to: pts[1], controlPoint1: cp1, controlPoint2: cp2)
            case .closeSubpath:
                self.close()
            @unknown default:
                break
            }
        }
    }
}
