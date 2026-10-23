import DigUpKit
import SwiftUI

/// Required words in the search field (`RequiredWords`, approved 2026-10-22), the same in the window and the panel: a
/// `+beach` typed in full becomes a "must have: beach" token after the filters (× or ⌫ in an empty field takes it
/// off), its word staying where it was typed; the query searched and saved has it marked again
/// (`RequiredWords.marking`). A right-click on a word of the field offers "Require “beach”" (`SearchField`), and until a
/// word has been required once, a tip under the field says how (`showsTip`).
enum RequiredTokens {
    /// What's typed, with each mark typed in full (`RequiredWords.Mark.isComplete`: a space after the word, or the
    /// phrase's quote closed) taken out and its term added to `required` (once). Nil when there's none, or in a search
    /// of code (`code`), where `+` is literal.
    static func taking(_ typed: String, into required: [String], code: Bool) -> (text: String, required: [String])? {
        guard !code else { return nil }
        let complete = RequiredWords.marks(in: typed).filter(\.isComplete)
        guard !complete.isEmpty else { return nil }
        return (RequiredWords.unmarking(complete, in: typed), RequiredWords.adding(complete.map(\.term), to: required))
    }

    /// A search with a required word was made: the tip has done its job (`AppSettings.requiredWordUsed`).
    static func noteUse(of query: String, code: Bool, in model: AppModel) {
        guard !code, !model.settings.requiredWordUsed, !RequiredWords(query).terms.isEmpty else { return }
        AppSettings.saveRequiredWordUsed()
        model.settings.requiredWordUsed = true
    }

    static let tipText = "Put + before a word that must be there: +beach, or right-click the word"

    /// Whether the tip shows under the field: words typed (two or more that count, `Searcher.terms`), none of them
    /// required, in a search that isn't of code, until a word has been required once.
    static func showsTip(query: String, required: [String], code: Bool, used: Bool) -> Bool {
        !used && !code && required.isEmpty && RequiredWords(query).terms.isEmpty && Searcher.terms(query).count >= 2
    }
}

/// A required word or phrase in the search field, before the words: "must have: beach", × to take it off.
struct RequiredTokenView: View {
    let term: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus").font(.system(size: 9, weight: .bold))
            Text("\(Text("must have: ").foregroundStyle(.secondary))\(Text(term))")
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: 190)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).opacity(0.6)
            }
            .buttonStyle(.plain)
            .help("Don't require it (⌫ in an empty field)")
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.leading, 8)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
        .fixedSize()
        .help("Every result must have “\(term)”: in its words (names, text, what Photos knows, what's said), or by what "
              + "it shows")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Must have: \(term)")
    }
}

/// Under the search field until a word has been required once (`RequiredTokens.showsTip`).
struct RequiredWordTip: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "lightbulb").font(.system(size: 10))
            Text(RequiredTokens.tipText)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}
