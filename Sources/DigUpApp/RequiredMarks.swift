import AppKit
import DigUpKit
import SwiftUI

/// Required words in the search field (`RequiredWords`, approved 2026-10-22), the same in the window and the panel:
/// `+beach` and `+"a phrase"` stay in the words where they're typed, drawn in the accent color on a tint
/// (`MarkingFieldCell`), so what's searched and saved is the field's text as it is (Jon, 2026-10-23: "Whatever you think
/// looks best"). A right-click on a word offers "Require “beach”", which types its `+` (`FocusReportingField`), and
/// until a word has been required once, a tip under the field says how (`showsTip`).
enum RequiredMarks {
    /// A search with a required word was made: the tip has done its job (`AppSettings.requiredWordUsed`).
    static func noteUse(of query: String, code: Bool, in model: AppModel) {
        guard !code, !model.settings.requiredWordUsed, !RequiredWords(query).terms.isEmpty else { return }
        AppSettings.saveRequiredWordUsed()
        model.settings.requiredWordUsed = true
    }

    static let tipText = "Put + before a word that must be there: +beach, or right-click the word"

    /// Whether the tip shows under the field: words typed (two or more that count, `Searcher.terms`), none of them
    /// required, in a search that isn't of code, until a word has been required once.
    static func showsTip(query: String, code: Bool, used: Bool) -> Bool {
        !used && !code && RequiredWords(query).terms.isEmpty && Searcher.terms(query).count >= 2
    }

    /// Where the field draws `text`'s marks (`RequiredWords.Mark.drawn`), as AppKit counts.
    static func ranges(in text: String) -> [NSRange] {
        RequiredWords.marks(in: text).map { NSRange($0.drawn, in: text) }
    }

    /// A mark's words, and the tint behind them.
    static let textColor = NSColor.controlAccentColor
    static let tint = NSColor.controlAccentColor.withAlphaComponent(0.16)

    /// The tint behind each of `ranges`, as `layout` lays them out in `container` with its origin at `origin`: a
    /// rounded box a little wider than the words.
    static func drawTints(_ ranges: [NSRange], _ layout: NSLayoutManager, _ container: NSTextContainer,
                          at origin: NSPoint) {
        tint.setFill()
        let noSelection = NSRange(location: NSNotFound, length: 0)
        for range in ranges {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: noSelection,
                                           in: container) { rect, _ in
                let box = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1.5, dy: 0.5)
                NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            }
        }
    }
}

/// The search field's cell (`FocusReportingField`): with `marksRequired`, its required words are drawn marked
/// (`RequiredMarks`), by a field editor of its own while it's edited (`MarkingFieldEditor`), and by the cell, laid out
/// as that editor lays them out, while it isn't.
final class MarkingFieldCell: NSTextFieldCell {
    var marksRequired = false {
        didSet { editor?.marksRequired = marksRequired }
    }
    private var editor: MarkingFieldEditor?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        let editor = self.editor ?? MarkingFieldEditor.make()
        editor.marksRequired = marksRequired
        self.editor = editor
        return editor
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let text = stringValue
        let ranges = marksRequired ? RequiredMarks.ranges(in: text) : []
        // While it's edited, its editor draws the words.
        guard !ranges.isEmpty, let font, (controlView as? NSControl)?.currentEditor() == nil else {
            return super.drawInterior(withFrame: cellFrame, in: controlView)
        }
        let storage = NSTextStorage(string: text, attributes: [.font: font,
                                                               .foregroundColor: textColor ?? .controlTextColor])
        for range in ranges { storage.addAttribute(.foregroundColor, value: RequiredMarks.textColor, range: range) }
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = MarkingFieldEditor.padding
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let origin = titleRect(forBounds: cellFrame).origin
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: cellFrame).addClip()
        RequiredMarks.drawTints(ranges, layout, container, at: origin)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The search field's field editor (`MarkingFieldCell`): its required words drawn marked as they're typed (TextKit 1,
/// for where its words are). The color is the layout manager's, given as it draws (`layoutManager(_:
/// shouldUseTemporaryAttributes:…)`), so the text, what's typed next and undo stay as they are.
final class MarkingFieldEditor: NSTextView, NSLayoutManagerDelegate, NSTextStorageDelegate {
    /// The space before the first letter, as a field editor has it.
    static let padding: CGFloat = 2

    var marksRequired = false {
        didSet { if marksRequired != oldValue { needsDisplay = true } }
    }
    /// The marks of the text as last read.
    private var marked: (text: String, ranges: [NSRange]) = ("", [])

    static func make() -> MarkingFieldEditor {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = padding
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let editor = MarkingFieldEditor(frame: .zero, textContainer: container)
        editor.isFieldEditor = true
        layout.delegate = editor
        storage.delegate = editor
        return editor
    }

    private var ranges: [NSRange] {
        guard marksRequired else { return [] }
        if marked.text != string { marked = (string, RequiredMarks.ranges(in: string)) }
        return marked.ranges
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer, !ranges.isEmpty else { return }
        RequiredMarks.drawTints(ranges, layoutManager, textContainer, at: textContainerOrigin)
    }

    /// Any change draws all of it again: a `+` typed marks the word after it, or the one it's typed in ("+" then "b").
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) { needsDisplay = true }
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any] = [:],
                       forDrawingToScreen toScreen: Bool, atCharacterIndex charIndex: Int,
                       effectiveRange effectiveCharRange: NSRangePointer?) -> [NSAttributedString.Key: Any]? {
        var attributes = attrs
        let ranges = self.ranges
        // Up to where it's marked or not any more.
        var until = NSRange(location: charIndex, length: max((string as NSString).length - charIndex, 1))
        if let mark = ranges.first(where: { NSLocationInRange(charIndex, $0) }) {
            attributes[.foregroundColor] = RequiredMarks.textColor
            until = mark
        } else if let next = ranges.first(where: { $0.location > charIndex }) {
            until = NSRange(location: charIndex, length: next.location - charIndex)
        }
        if let effectiveCharRange {
            let given = effectiveCharRange.pointee
            effectiveCharRange.pointee = NSLocationInRange(charIndex, given) ? NSIntersectionRange(given, until) : until
        }
        return attributes
    }
}

/// Under the search field until a word has been required once (`RequiredMarks.showsTip`).
struct RequiredWordTip: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "lightbulb").font(.system(size: 10))
            Text(RequiredMarks.tipText)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}
