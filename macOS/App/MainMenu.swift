import AppKit

/// The menu bar shown while a Corvin window is open (the app is an accessory
/// otherwise). Built by hand since there is no SwiftUI `App` to provide one;
/// the Edit menu is what makes ⌘C/⌘V/⌘A work in text fields.
enum MainMenu {
    static func make(settingsTarget: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let app = submenu(of: main, title: "Corvin")
        let settings = item("menu.settings", #selector(AppDelegate.showSettingsFromMenu(_:)), ",")
        settings.target = settingsTarget
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(item("menu.app.hide", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("menu.quit", #selector(NSApplication.terminate(_:)), "q"))

        let edit = submenu(of: main, title: "menu.edit".localized)
        edit.addItem(item("menu.edit.undo", Selector(("undo:")), "z"))
        let redo = item("menu.edit.redo", Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(item("menu.edit.cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("menu.edit.copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("menu.edit.paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("menu.edit.selectAll", #selector(NSText.selectAll(_:)), "a"))

        let window = submenu(of: main, title: "menu.window".localized)
        window.addItem(item("menu.window.minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("menu.window.close", #selector(NSWindow.performClose(_:)), "w"))
        NSApplication.shared.windowsMenu = window

        return main
    }

    private static func submenu(of main: NSMenu, title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    /// Target nil: the action goes to the first responder that handles it.
    private static func item(_ key: String, _ action: Selector, _ keyEquivalent: String) -> NSMenuItem {
        NSMenuItem(title: key.localized, action: action, keyEquivalent: keyEquivalent)
    }
}
