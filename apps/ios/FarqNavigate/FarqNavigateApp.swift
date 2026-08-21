import SwiftUI

@main
struct FarqNavigateApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                /* The product is Arabic first. Forcing the layout direction here
                 * rather than relying on the device keeps the simulator honest
                 * about what a customer will see. */
                .environment(\.layoutDirection, .rightToLeft)
        }
    }
}
