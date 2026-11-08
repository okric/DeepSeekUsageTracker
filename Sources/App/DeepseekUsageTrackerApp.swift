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
                    UserDefaults.standard.set(true, forKey: "didConfigureLoginItem")
                    UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "loginItemPath")
                    print("login-register: ok")
                } catch {
                    print("login-register: \(error)")
                }
                printLoginStatus()
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--login-unregister") {
            Task { @MainActor in
                do {
                    try await SMAppService.mainApp.unregister()
                    UserDefaults.standard.set(true, forKey: "didConfigureLoginItem")
                    UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "loginItemPath")
                    print("login-unregister: ok")
                } catch {
                    print("login-unregister: \(error)")
                }
                printLoginStatus()
                exit(0)
            }
            RunLoop.main.run()
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
    private var updater: UpdaterController?
    private var statusController: StatusItemController?
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The test bundle loads the app as its host. Keep unit tests free of
        // file reads, timers, and network requests.
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return
        }

        let model = AppModel()
        self.model = model
        let updater = UpdaterController()
        self.updater = updater
        let settings = SettingsWindowController(model: model)
        self.settingsController = settings
        self.statusController = StatusItemController(
            model: model,
            updater: updater,
            openSettings: { [weak settings] in settings?.show() })

        model.start()

        let defaults = UserDefaults.standard
        // Show setup on first launch only when no Harness login can be found
        // (harnessSetupError is only meaningful after the first refresh).
        if !model.harnessAvailable && !defaults.bool(forKey: "hasLaunchedBefore") {
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
