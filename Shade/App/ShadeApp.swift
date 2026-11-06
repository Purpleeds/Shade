import SwiftUI

@main
struct ShadeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onOpenURL { url in model.importRecipe(from: url) }
                .onChange(of: scenePhase) { phase in model.handleScenePhase(phase) }
        }
    }
}
