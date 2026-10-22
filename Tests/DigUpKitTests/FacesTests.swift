import Foundation
import Testing
@testable import DigUpKit
#if canImport(Vision) && canImport(CoreML)
import CoreGraphics
#endif

/// Telling people apart by their faces (`Faces`): the alignment's arithmetic, the comparison, and the measurement
/// `digup faces-eval` reports.
@Suite struct FacesTests {
    /// A turn by 25°, a scale of 2 and a shift, as `Similarity` spells it.
    static let move = Faces.Similarity(a: 2 * cos(25 * Double.pi / 180), b: 2 * sin(25 * Double.pi / 180),
                                       tx: 120, ty: 20)

    @Test func theSimilarityFoundIsTheOneThatMovedThePoints() throws {
        let template = Faces.template(side: Faces.arcFaceSide)
        let moved = template.map(Self.move.applied(to:))
        let found = try #require(Faces.Similarity(taking: template, to: moved))
        for (value, expected) in [(found.a, Self.move.a), (found.b, Self.move.b), (found.tx, Self.move.tx),
                                  (found.ty, Self.move.ty)] {
            #expect(abs(value - expected) < 1e-9)
        }
        // Nothing to go by: no points, points all in one place, or lists that don't pair up.
        #expect(Faces.Similarity(taking: [], to: []) == nil)
        let one = Faces.Point(x: 3, y: 4)
        #expect(Faces.Similarity(taking: [one, one], to: Array(template.prefix(2))) == nil)
        #expect(Faces.Similarity(taking: template, to: Array(moved.prefix(4))) == nil)
    }

    @Test func cosineComparesDirectionsNotLengths() {
        #expect(Faces.cosine([1, 0], [2, 0]) == 1)
        #expect(Faces.cosine([1, 0], [0, 3]) == 0)
        #expect(abs(Faces.cosine([1, 1], [-1, -1]) + 1) < 1e-6)
        #expect(Faces.cosine([0, 0], [1, 0]) == 0)          // no direction
        #expect(Faces.cosine([1, 0, 0], [1, 0]) == 0)       // not the same recognizer's
    }

    /// Two people of two faces each, one person of one face, and two faces nobody named: each named face is called by
    /// the nearest of the others, each unnamed one by the nearest named face.
    @Test func eachFaceIsCalledByItsNearestNamedFace() {
        let named: [(person: String, embedding: [Float])] = [
            ("A", [1, 0]), ("A", [0.6, 0.8]),     // nearer B's faces (0.91 at most) than A's other (0.6): called B
            ("B", [0, 1]), ("B", [0.2, 0.9]),
            ("C", [-1, 0]),                       // no other face of C's: left out
        ]
        let measure = Faces.Measure(named: named, others: [[0.7, 0.7], [-0.5, -0.5]], similarity: Faces.cosine)
        #expect(measure.alone == 1)
        #expect(measure.calls.map(\.right) == [true, false, true, true])
        #expect(measure.nearestRight == 0.75)
        #expect(measure.rates(at: 0.5) == Faces.Measure.Rates(right: 0.75, wrong: 0.25, uncalled: 0, others: 1))
        // At 0.7, A's [1, 0] (0.6 from A's other face) isn't called; the face nearest C's (0.71) still is.
        #expect(measure.rates(at: 0.7) == Faces.Measure.Rates(right: 0.5, wrong: 0.25, uncalled: 0.25, others: 1))
        // At 0.8, only the face nearly on A's [0.6, 0.8] (0.99) is still called someone.
        #expect(measure.rates(at: 0.8).others == 0.5)
        #expect(measure.rates(at: 0.995) == Faces.Measure.Rates(right: 0, wrong: 0, uncalled: 1, others: 0))
    }

    #if canImport(Vision) && canImport(CoreML)
    /// A picture with five colored dots where a face's five points would be, turned, scaled and moved (`move`): aligned,
    /// each dot lands on its point of the template.
    @Test func aligningPutsTheFivePointsOnTheTemplate() throws {
        let (width, height) = (400, 300)
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (1, 0, 1)]
        let points = Faces.template(side: Faces.arcFaceSide).map(Self.move.applied(to:))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (point, color) in zip(points, colors) {   // points are from the top, Core Graphics from the bottom
            context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
            context.fillEllipse(in: CGRect(x: point.x - 6, y: Double(height) - point.y - 6, width: 12, height: 12))
        }
        let picture = try #require(context.makeImage())

        let side = Int(Faces.arcFaceSide)
        let aligned = try #require(Faces.aligned(picture, points: points, side: side))
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let reading = try #require(CGContext(data: &rgba, width: side, height: side, bitsPerComponent: 8,
                                             bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        reading.draw(aligned, in: CGRect(x: 0, y: 0, width: side, height: side))
        func pixel(_ point: Faces.Point) -> (Int, Int, Int) {
            let index = (Int(point.y) * side + Int(point.x)) * 4   // the first row is the top one
            return (Int(rgba[index]), Int(rgba[index + 1]), Int(rgba[index + 2]))
        }
        for (point, color) in zip(Faces.template(side: Faces.arcFaceSide), colors) {
            let (red, green, blue) = pixel(point)
            #expect((red > 200, green > 200, blue > 200) == (color.0 == 1, color.1 == 1, color.2 == 1),
                    "at \(point): \(red), \(green), \(blue)")
            #expect((red < 60, green < 60, blue < 60) == (color.0 == 0, color.1 == 0, color.2 == 0),
                    "at \(point): \(red), \(green), \(blue)")
        }
        let (red, green, blue) = pixel(Faces.Point(x: 56, y: 30))   // the forehead: the gray around the dots
        #expect(abs(red - 128) <= 2 && abs(green - 128) <= 2 && abs(blue - 128) <= 2)
    }
    #endif
}
