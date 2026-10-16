import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { true }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Player", sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let library = LibraryController()
        window.rootViewController = library
        self.window = window
        if let url = options.urlContexts.first?.url, url.isFileURL { library.pendingFileURL = url }
        #if DEBUG
        // Developer-only playback probe. Release builds never read this environment variable.
        if library.pendingFileURL == nil, let name = ProcessInfo.processInfo.environment["VR_TEST_MOVIE"], name == URL(fileURLWithPath: name).lastPathComponent {
            library.pendingFileURL = URL.documentsDirectory.appending(path: "Movies").appending(path: name)
        }
        #endif
        window.makeKeyAndVisible()
    }
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let url = contexts.first?.url, url.isFileURL else { return }
        (window?.rootViewController as? LibraryController)?.openFile(url)
    }
}
