//
//  IRISApp.swift
//  IRIS — Integration (Phase 2, solo)
//
//  SwiftUI entry point. All real lifecycle/wiring lives in `AppDelegate`; this just hosts
//  it. There is no main window — IRIS is a menu-bar accessory with a floating overlay — so
//  the only scene is an empty `Settings` scene.
//
//  Note: `Settings` here is SwiftUI's settings *scene*, disambiguated from IRIS's own
//  `Settings` config type (IRIS/Config/Settings.swift) via the explicit `SwiftUI.` prefix.
//

import SwiftUI

@main
struct IRISApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        SwiftUI.Settings {
            EmptyView()
        }
    }
}
