import Foundation

/// How a result is told to people: why it's there and where it matched ("Matches the frame at 0:06"). The app's results
/// and `digup mcp` say the same.
public enum MatchDescription {
    /// A time into a recording: "0:06", "1:02:03".
    public static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The lines (or a notebook's cells) of code that matched: "lines 12–40", "cell 3".
    public static func span(_ segment: SegmentKind, loc: Double?, locEnd: Double?) -> String? {
        guard let loc else { return nil }
        let (first, last) = (Int(loc), Int(locEnd ?? loc))
        switch segment {
        case .lines: return first == last ? "line \(first)" : "lines \(first)–\(last)"
        case .cells: return first == last ? "cell \(first)" : "cells \(first)–\(last)"
        default: return nil
        }
    }

    /// Why it's here, in a few words: "Matches the picture", "Matches the frame at 0:06", "Has your words in Photos",
    /// "Tatiana Rotari, by their face". `meaning`: its meaning stood out for the query; `words`: keyword search found
    /// the query's words in it; `listed`: a filter keeps it and no words were given; `faces`: the people the People
    /// filter took faces in it for (a picture outside Photos, `SearchHit.faces`), by their names in Photos.
    public static func reason(_ segment: SegmentKind, kind: FileKind, loc: Double?, locEnd: Double?, meaning: Bool,
                              words: Bool, listed: Bool, reading: PhotosLibrary.Reading?,
                              faces: [String] = []) -> String {
        let matched = whatMatched(segment, kind: kind, loc: loc, locEnd: locEnd, meaning: meaning, words: words,
                                  listed: listed, reading: reading)
        guard !faces.isEmpty else { return matched }
        var names: [String] = []
        for name in faces where !names.contains(name) { names.append(name) }
        let byFace = "\(spoken(names)), by \(faces.count == 1 ? "their face" : "their faces")"
        return meaning || words ? matched + " · " + byFace : byFace
    }

    /// Names as said: "Tati", "Tati and Chris", "Tati, Chris and Sam".
    static func spoken(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// What of it matched the query, or else why it's here.
    private static func whatMatched(_ segment: SegmentKind, kind: FileKind, loc: Double?, locEnd: Double?,
                                    meaning: Bool, words: Bool, listed: Bool, reading: PhotosLibrary.Reading?) -> String {
        guard meaning else {
            // Photos' words: a person's name, a place, a keyword or an album.
            if words, segment == .photosInfo { return "Has your words in Photos" }
            if words, segment == .speech, let loc { return "Says your words at \(clock(loc))" }
            if words { return "Has your words" }
            return listed ? "Fits your filters" : "Matches its name"
        }
        let place = loc.map(clock) ?? ""
        let page = loc.map { "page \(Int($0))" } ?? "a page"
        switch segment {
        case .image: return kind == .screenshot ? "Matches what's on screen" : "Matches the picture"
        case .ocr: return "Matches the text in it"
        case .frame:
            if kind == .image { return "Matches a frame of the animation" }
            if reading == .stills { return "Matches one of Photos' stills of it" }
            if reading == .poster { return "Matches its poster" }
            return "Matches the frame at \(place)"
        case .audio: return kind == .video ? "Matches the sound at \(place)" : "Matches what's heard at \(place)"
        case .page: return "Matches the text on \(page)"
        case .pageImage: return "Matches \(page)"
        case .chunk: return "Matches its text"
        case .name: return "Matches its name"
        case .photosInfo: return "Matches what Photos knows about it"
        case .lines, .cells: return "Matches \(span(segment, loc: loc, locEnd: locEnd) ?? "the code")"
        case .speech: return "Matches what's said at \(place)"
        }
    }
}
