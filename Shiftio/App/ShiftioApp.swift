import SwiftUI

@main
struct ShiftioApp: App {
    @State private var app = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(app: app)
        } label: {
            // Template images, so they follow the menu bar's tint like system extras do. The resting icon is
            // Shiftio's own (two open rings); busy and error states use system symbols.
            if app.hasUnseenError {
                Image(systemName: "exclamationmark.circle")
            } else if app.runningCount > 0 {
                Image(systemName: "arrow.triangle.2.circlepath").symbolEffect(.rotate, isActive: true)
            } else if app.keepAwake != nil {
                // Keep Awake is on: a cup with steam that keeps rising, so it is clear the Mac is being held awake.
                Image(systemName: "cup.and.heat.waves.fill")
                    .symbolEffect(.variableColor.iterative.reversing, isActive: true)
            } else {
                Image("MenuBarIcon")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
