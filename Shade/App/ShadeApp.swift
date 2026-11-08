import SwiftUI

@main
struct ShadeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.looks)
                .preferredColorScheme(.dark)
                .onOpenURL { url in model.open(url) }
                .onChange(of: scenePhase) { phase in model.handleScenePhase(phase) }
        }
    }
}
