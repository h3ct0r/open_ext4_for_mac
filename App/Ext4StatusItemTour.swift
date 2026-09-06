//
//  Ext4StatusItemTour.swift — pointing at the interface
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Ext4Mac has no window. Everything it offers a person -- unlocking an
//  encrypted volume, what the extension last refused and why, the way back to
//  the Setup Assistant -- is behind one small icon in the menu bar, and a menu
//  bar on a modern Mac is a crowded place with a notch in the middle of it.
//
//  So the wizard finishes by pointing: the icon blinks and takes the accent
//  colour, a callout appears beside it, and then the menu opens by itself so
//  the person has read the thing while looking at it.
//
//  The menu is opened with performClick and never awaited. Menu tracking nests
//  the run loop, so anything waiting on the far side of that call waits until
//  the menu closes -- the tour is resumed from menuDidClose instead.
//

import AppKit
import SwiftUI

@MainActor
enum Ext4StatusItemTour {
    private static var popover: NSPopover?

    /// Blink the icon, then offer to open the menu. `openMenu` is called when
    /// the person asks for it.
    static func run(on button: NSStatusBarButton, openMenu: @escaping () -> Void) {
        pulse(button)
        // After the blink, not during it: a callout that appears on top of the
        // thing it is pointing at hides the thing it is pointing at.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            show(TourCallout(
                title: "This is Ext4Mac.",
                text: """
                    Encrypted volumes, what the extension last refused and why, and \
                    the way back to this setup — all of it is in this menu.
                    """,
                button: "Open the Menu",
                action: {
                    dismiss()
                    openMenu()
                }),
                 on: button)
        }
    }

    /// After the menu has been opened and closed again.
    static func finish(on button: NSStatusBarButton?, then done: @escaping () -> Void) {
        guard let button else { done(); return }
        show(TourCallout(
            title: "That is the whole interface.",
            text: """
                The header says whether the extension is enabled. Attached encrypted \
                volumes appear with Unlock, Mount and Forget Key. Recent Issues is what \
                the extension refused and why. Open at Login keeps the extension \
                registered across restarts.
                """,
            button: "Done",
            action: {
                dismiss()
                done()
            }),
             on: button)
    }

    // MARK: -

    /// Three blinks and then the accent colour for a moment. The menu-bar
    /// image is a template, so tinting it actually shows.
    private static func pulse(_ button: NSStatusBarButton) {
        func blink(_ remaining: Int) {
            guard remaining > 0 else {
                button.contentTintColor = .controlAccentColor
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    button.contentTintColor = nil
                }
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                button.animator().alphaValue = 0.15
            }, completionHandler: {
                MainActor.assumeIsolated {
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.35
                        button.animator().alphaValue = 1
                    }, completionHandler: {
                        MainActor.assumeIsolated { blink(remaining - 1) }
                    })
                }
            })
        }
        blink(3)
    }

    private static func show(_ view: TourCallout, on button: NSStatusBarButton) {
        dismiss()
        // A button with no window is an icon macOS has hidden -- behind the
        // notch, or in an overflow menu. Nothing can be anchored to it, so the
        // callout becomes a sentence that tells the person where to look.
        guard button.window != nil else {
            let alert = NSAlert()
            alert.messageText = view.title
            alert.informativeText = view.text + "\n\nLook for the drive icon in the menu bar; "
                                  + "it may be hidden behind the notch."
            alert.addButton(withTitle: view.button)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            view.action()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: view)
        popover.contentSize = NSSize(width: 320, height: 190)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
    }

    private static func dismiss() {
        popover?.performClose(nil)
        popover = nil
    }
}

private struct TourCallout: View {
    let title: String
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(text).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button(button, action: action).keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 320)
    }
}
