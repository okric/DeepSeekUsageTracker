import AppKit
import Darwin
import ServiceManagement

@main
struct DeepseekUsageTrackerApp {
    static func main() {
        if CommandLine.arguments.contains("--login-status") {
            MainActor.assumeIsolated { printLoginStatus() }
            exit(0)
        }
        if CommandLine.arguments.contains("--login-register") {
            MainActor.assumeIsolated {
                do {
                    try SMAppService.mainApp.register()
                    print("login-register: ok")
                } catch {
                    print("login-register: \(error)")
                }
                printLoginStatus()
            }
            exit(0)
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            // NSApplication holds its delegate weakly, so keep the local alive
            // for the duration of the run loop.
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }

    @MainActor
    private static func printLoginStatus() {
        let status = SMAppService.mainApp.status
        print("login-status: raw=\(status.rawValue) \(status)")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusController: StatusItemController?
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The test bundle loads the app as its host. Keep unit tests free of
        // Keychain reads, timers, and network requests.
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return
        }

        let model = AppModel()
        self.model = model
        let settings = SettingsWindowController(model: model)
        self.settingsController = settings
        self.statusController = StatusItemController(
            model: model,
            openSettings: { [weak settings] in settings?.show() })

        model.start()

        let defaults = UserDefaults.standard
        if !model.hasAnyCredential && !defaults.bool(forKey: "hasLaunchedBefore") {
            defaults.set(true, forKey: "hasLaunchedBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                settings.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
