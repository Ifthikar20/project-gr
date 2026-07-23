import SwiftUI

@main
struct GemRunApp: App {
    @State private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(session)
                .preferredColorScheme(.dark)
        }
    }
}
