import Foundation
import Testing
@testable import DigUpKit

/// What's said in a recording as stretches of speech (`Speech.stretches(of:)`): consecutive sentences up to about 30 s
/// or 60 words, never across a silence longer than 2 s, each from its first word's start to its last word's end.
@Suite struct SpeechTests {
    typealias Token = Speech.Sentence.Token

    /// A sentence as parakeet-mlx gives one: `words` words from `start`, one every `pace` seconds (each half as long),
    /// then its full stop, a token of its own.
    static func sentence(_ start: Double, words: Int, pace: Double = 0.5) -> Speech.Sentence {
        let said = (0..<words).map { Token(text: " word", start: start + Double($0) * pace,
                                           end: start + Double($0) * pace + pace / 2) }
        let end = said.last?.end ?? start
        return Speech.Sentence(tokens: said + [Token(text: ".", start: end, end: end + 0.25)])
    }

    /// Sentences of 15 words, 7.25 s long, 0.75 s apart: three make a stretch, and a fourth would take it to 31.25 s
    /// (with 60 words, which a stretch may hold), so it starts the next one.
    @Test func aStretchEndsBeforeItRunsPast30Seconds() {
        let stretches = Speech.stretches(of: stride(from: 0.0, to: 40, by: 8).map { Self.sentence($0, words: 15) })
        #expect(stretches.map { [$0.start, $0.end] } == [[0, 23.25], [24, 39.25]])
    }

    /// Sentences of 25 words, 6.125 s long, 0.375 s apart: two make a stretch of 50 words, and a third would take it to
    /// 75 (in 19.125 s), so it starts the next one.
    @Test func aStretchHoldsAtMost60Words() {
        let stretches = Speech.stretches(of: [0, 6.5, 13].map { Self.sentence($0, words: 25, pace: 0.25) })
        #expect(stretches.map { [$0.start, $0.end] } == [[0, 12.625], [13, 19.125]])
        #expect(stretches.first?.text.split(separator: " ").count == 50)
    }

    /// A silence of 2.5 s after a sentence ends its stretch; one of 1.5 s doesn't. parakeet-mlx, cutting sentences at a
    /// silence, hears the first one's full stop at the silence's end, as a sentence of its own: it ends the first
    /// stretch, whose time is its words'.
    @Test func aSilenceLongerThan2SecondsEndsAStretch() {
        let first = Speech.Sentence(tokens: (0..<5).map { Token(text: " word", start: Double($0) * 0.5,
                                                                 end: Double($0) * 0.5 + 0.25) })
        let stop = Speech.Sentence(tokens: [Token(text: ".", start: 4.5, end: 4.75)])
        let stretches = Speech.stretches(of: [first, stop, Self.sentence(4.75, words: 5), Self.sentence(8.5, words: 5)])
        #expect(stretches.map { [$0.start, $0.end] } == [[0, 2.25], [4.75, 10.75]])
        #expect(stretches.first?.text == "word word word word word.")
    }
}
