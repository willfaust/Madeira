import SwiftUI

@main
struct MadeiraApp: App {
    init() {
        GamepadBridge.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
