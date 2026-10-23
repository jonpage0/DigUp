import AppKit
import DigUpKit
import Observation
import SwiftUI

/// When's Custom Range… (the search window's Filters menu): a sheet that asks for the days a search keeps to, from a
/// first day to a last one, both kept, either end left open. An AppKit window, as the saved-search sheets are, so a
/// snapshot run draws it without showing it.
final class CustomWhenSheet {
    private var sheet: NSWindow?
    private unowned let app: AppController
    /// The open sheet's Use (`-debugWhenSheet use` presses it).
    private(set) var use: (() -> Void)?

    init(app: AppController) {
        self.app = app
    }

    var isOpen: Bool { sheet != nil }

    /// Asks for the days, `current`'s filled in (the past month's without one); Use gives `chosen` them.
    func begin(from current: SearchFilter.When?, on window: NSWindow?,
               chosen: @escaping (SearchFilter.When) -> Void) {
        end()
        let range = CustomWhenRange(current)
        let use: () -> Void = { [weak self] in
            guard let when = range.when else { return }
            chosen(when)
            self?.end()
        }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: CustomWhenView(
            range: range, use: use, cancel: { [weak self] in self?.end() })))
        sheet.styleMask = [.titled]
        sheet.title = FilterMenuItem.customRangeTitle
        self.sheet = sheet
        self.use = use
        guard !AppController.offscreen else { return }   // snapshot runs draw it without showing it
        if let window, window.isVisible { window.beginSheet(sheet) } else { app.present(sheet) }
    }

    func end() {
        if let sheet {
            if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.close() }
        }
        sheet = nil
        use = nil
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(sheet, to: url)
    }
}

/// The days Custom Range… is asking for: a first day and a last one, each on or left open.
@Observable
final class CustomWhenRange {
    var from: Date
    var through: Date
    var hasFrom = true
    var hasThrough = true

    /// `current`'s days, or for the last so many days, those days up to today; without one, the past month.
    init(_ current: SearchFilter.When?) {
        let today = SearchFilter.Day(Date())
        switch current?.span {
        case .days(let after, let before):
            (hasFrom, hasThrough) = (after != nil, before != nil)
            from = (after ?? today.adding(days: -30)).start()
            through = (before?.adding(days: -1) ?? today).start()
        case .lastDays(let days):
            (from, through) = (today.adding(days: -days).start(), today.start())
        case nil:
            (from, through) = (today.adding(days: -30).start(), today.start())
        }
    }

    /// What Use puts on: from the first day to the day after the last (a When's `before` isn't kept); nil with
    /// neither end, or the first day after the last.
    var when: SearchFilter.When? {
        SearchFilter.When(after: hasFrom ? SearchFilter.Day(from) : nil,
                          before: hasThrough ? SearchFilter.Day(through).adding(days: 1) : nil)
    }

    /// Why Use can't be pressed, if it can't.
    var problem: String? {
        guard when == nil else { return nil }
        return hasFrom || hasThrough ? "The first day is after the last." : "Choose a first day, a last day, or both."
    }
}

/// Custom Range…: the first day and the last one, each with a switch to leave it open, and Use.
private struct CustomWhenView: View {
    @Bindable var range: CustomWhenRange
    let use: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Range").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Toggle("From", isOn: $range.hasFrom)
                    DatePicker("From", selection: $range.from, displayedComponents: .date)
                        .labelsHidden()
                        .disabled(!range.hasFrom)
                }
                GridRow {
                    Toggle("Through", isOn: $range.hasThrough)
                    DatePicker("Through", selection: $range.through, displayedComponents: .date)
                        .labelsHidden()
                        .disabled(!range.hasThrough)
                }
            }
            Text(range.problem ?? "Files from these days, both included: when Photos or the camera says it was taken, "
                 + "else when the file was last changed. Turn an end off to leave it open.")
                .font(.system(size: 11))
                .foregroundStyle(range.problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Use", action: use)
                    .keyboardShortcut(.defaultAction)
                    .disabled(range.when == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
