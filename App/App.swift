import UIKit
import TelegramShell

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        // The demo runs in the dark theme (Telegram's Night, with its patterned wallpaper).
        // Launch with -light to follow the system appearance instead.
        if !ProcessInfo.processInfo.arguments.contains("-light") {
            window.overrideUserInterfaceStyle = .dark
        }
        // The demo opens straight in a chat. Change the conversation in DemoData (or pass your own DemoChat),
        // set startInChat: false to start on the chat list.
        let history = History.make()
        window.rootViewController = ShellApp.makeRoot(
            chats: [history.chat] + DemoData.chats.dropFirst(),
            startInChat: true,
            features: [TimelineZoomFeature(summary: { history.summaries[$0] })]
        )
        window.makeKeyAndVisible()
        self.window = window
    }
}
