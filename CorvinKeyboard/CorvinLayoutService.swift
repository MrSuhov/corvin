import KeyboardKit
import SwiftUI

/// Builds the Corvin keyboard layout: English QWERTY or Russian ЙЦУКЕН plus
/// mic button and (optional) language-switch button on the bottom row.
///
/// KeyboardKit 10.x removed `KeyboardLayoutService` — layouts are now values
/// passed directly to `KeyboardView(layout:)`. This is the replacement for the
/// old `CorvinLayoutService: KeyboardLayout.StandardService`.
enum CorvinLayout {

    static func make(for context: KeyboardContext, showLanguageButton: Bool) -> KeyboardLayout {
        var layout: KeyboardLayout
        if context.locale.identifier.hasPrefix("ru") && context.keyboardType == .alphabetic {
            layout = makeIPhoneLayout(inputSet: .russian, context: context)
        } else {
            layout = KeyboardLayout.standard(for: context)
        }
        addCustomButtons(to: &layout, showLanguageButton: showLanguageButton)
        return layout
    }

    /// Build an iPhone-style layout by substituting the letter rows of the
    /// standard English layout with characters from the given input set.
    /// Only call this in alphabetic mode — numeric/symbolic layouts contain
    /// digits and symbols, not letters, so substitution would clobber them.
    private static func makeIPhoneLayout(inputSet: KeyboardLayout.InputSet, context: KeyboardContext) -> KeyboardLayout {
        var layout = KeyboardLayout.standard(for: context)
        let rows = inputSet.rows
        let device = context.deviceTypeForKeyboard
        let kbCase = context.keyboardCase

        for i in 0..<min(rows.count, layout.itemRows.count) {
            let items = rows[i].items(for: device)
            let oldRow = layout.itemRows[i]

            guard let template = oldRow.first(where: { Self.isCharacter($0.action) }) else { continue }

            let leading = oldRow.prefix { !Self.isCharacter($0.action) }
            let trailing = Array(oldRow.reversed().prefix { !Self.isCharacter($0.action) }.reversed())

            let charItems = items.map { item in
                KeyboardLayout.Item(
                    action: item.characterAction(for: kbCase),
                    size: template.size,
                    alignment: template.alignment,
                    edgeInsets: template.edgeInsets
                )
            }

            layout.itemRows[i] = Array(leading) + charItems + trailing
        }

        return layout
    }

    private static func isCharacter(_ action: KeyboardAction) -> Bool {
        if case .character = action { return true }
        return false
    }

    private static func addCustomButtons(to layout: inout KeyboardLayout, showLanguageButton: Bool) {
        let bottomIdx = layout.bottomRowIndex
        guard bottomIdx >= 0, bottomIdx < layout.itemRows.count else { return }
        guard let spaceIndex = layout.itemRows[bottomIdx].firstIndex(where: { $0.action == .space }) else { return }

        let spaceItem = layout.itemRows[bottomIdx][spaceIndex]

        // Shorten space bar so the mic (and optional lang) fit.
        let shorterSpace = KeyboardLayout.Item(
            action: .space,
            size: KeyboardLayout.ItemSize(width: .available, height: spaceItem.size.height),
            alignment: spaceItem.alignment,
            edgeInsets: spaceItem.edgeInsets
        )
        layout.itemRows[bottomIdx][spaceIndex] = shorterSpace

        let micItem = KeyboardLayout.Item(
            action: .custom(named: "corvin_mic"),
            size: KeyboardLayout.ItemSize(width: .points(42), height: spaceItem.size.height),
            alignment: spaceItem.alignment,
            edgeInsets: spaceItem.edgeInsets
        )

        if showLanguageButton {
            let langItem = KeyboardLayout.Item(
                action: .nextLocale,
                size: KeyboardLayout.ItemSize(width: .points(42), height: spaceItem.size.height),
                alignment: spaceItem.alignment,
                edgeInsets: spaceItem.edgeInsets
            )
            layout.itemRows[bottomIdx].insert(langItem, at: spaceIndex)
            layout.itemRows[bottomIdx].insert(micItem, at: spaceIndex + 2)
        } else {
            layout.itemRows[bottomIdx].insert(micItem, at: spaceIndex + 1)
        }
    }
}
