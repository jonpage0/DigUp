// Vector math on macOS: Accelerate. Platform/Portable has plain loops for Linux and Windows.
#if canImport(Accelerate)
import Accelerate

extension Vectors {
    /// Converts `count` float16s into float32s.
    static func floats(fromHalf source: UnsafePointer<Float16>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1,
                                 width: vImagePixelCount(count), rowBytes: count * 2)
        var to = vImage_Buffer(data: destination, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
        vImageConvert_Planar16FtoPlanarF(&from, &to, vImage_Flags(kvImageNoFlags))
    }

    /// `scores[i]` = the dot product of row `i` of `rows` (`count` rows of `dimension` floats) with `query`.
    static func scores(of rows: UnsafePointer<Float>, count: Int, query: UnsafePointer<Float>,
                       into scores: UnsafeMutablePointer<Float>) {
        vDSP_mmul(rows, 1, query, 1, scores, 1, vDSP_Length(count), 1, vDSP_Length(dimension))
    }

    /// `c` = `a` (`rows` × `inner`) times `b` (`inner` × `columns`), all row-major: many faces' prints scored against
    /// many at once (`FaceMatcher`).
    static func multiply(_ a: UnsafePointer<Float>, rows: Int, by b: UnsafePointer<Float>, columns: Int, inner: Int,
                         into c: UnsafeMutablePointer<Float>) {
        vDSP_mmul(a, 1, b, 1, c, 1, vDSP_Length(rows), vDSP_Length(columns), vDSP_Length(inner))
    }
}
#endif
