import Cocoa
import FlutterMacOS

/// Minerva runs as a background service: closing the window hides it (the Mac stops listening)
/// but the app keeps running, so the phone remote, workers and routines keep working. A menu bar
/// item opens the window again or quits. Started with `--background` (the login LaunchAgent), it
/// starts hidden. Its texts are in en.lproj / es.lproj (Localizable.strings), in Minerva's
/// language setting (see [setLanguage]), else the macOS preferred languages, like the Flutter UI's.
@main
class AppDelegate: FlutterAppDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem?
  private var activity: NSObjectProtocol?

  static let showNotification = Notification.Name("com.kidandcat.minerva.show")

  private var window: MainFlutterWindow? { mainFlutterWindow as? MainFlutterWindow }

  /// The lproj of Minerva's language setting; nil follows the macOS preferred languages.
  private static var languageBundle: Bundle?

  /// Applies Minerva's language setting (an lproj code such as "es", or nil for the system's) to
  /// the menus now. [save] (the user changed it): also to the menu bar and the system dialogs from
  /// the next launch, as the app's own language (they read it at launch).
  static func setLanguage(_ code: String?, save: Bool) {
    languageBundle = code.flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:))
    if !save {
      (NSApp.delegate as? AppDelegate)?.rebuildMenus()
      return
    }
    if let code {
      UserDefaults.standard.set([code], forKey: "AppleLanguages")
    } else {
      UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    }
    (NSApp.delegate as? AppDelegate)?.rebuildMenus()
  }

  /// The user's languages for all apps, most preferred first. Unlike Locale.preferredLanguages,
  /// it ignores this app's own setting, so "follow the system" works without a restart.
  static var systemLanguages: [String] {
    CFPreferencesCopyValue(
      "AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
      kCFPreferencesAnyHost) as? [String] ?? Locale.preferredLanguages
  }

  private static func localized(_ key: String) -> String {
    (languageBundle ?? Bundle.main).localizedString(forKey: key, value: nil, table: nil)
  }

  private func rebuildMenus() {
    statusItem?.menu = makeMenu()
    window?.contextMenu = makeMenu()
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Hidden, the app would otherwise be napped: its timers (routines, relay keepalive) slowed down.
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep],
      reason: "Minerva serves its phone remote and runs routines in the background")
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Minerva")
    item.menu = makeMenu()
    statusItem = item
    window?.contextMenu = makeMenu()
    // A second launch (Finder, Spotlight, `open`) asks this instance to show its window.
    DistributedNotificationCenter.default().addObserver(
      forName: Self.showNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.window?.showNormal() }
    if CommandLine.arguments.contains("--background") {
      NSApp.setActivationPolicy(.accessory)
    } else {
      window?.showNormal()
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    window?.showNormal()
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// True when another Minerva already runs for this user; unless this launch is the background
  /// one, that instance is asked to show its window. Test instances with their own data folder
  /// (MINERVA_DATA_DIR) may run side by side.
  static func handOffToRunningInstance() -> Bool {
    if ProcessInfo.processInfo.environment["MINERVA_DATA_DIR"] != nil { return false }
    guard let id = Bundle.main.bundleIdentifier else { return false }
    let me = ProcessInfo.processInfo.processIdentifier
    guard NSRunningApplication.runningApplications(withBundleIdentifier: id)
      .contains(where: { $0.processIdentifier != me && !$0.isTerminated })
    else { return false }
    if !CommandLine.arguments.contains("--background") {
      DistributedNotificationCenter.default().postNotificationName(
        showNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
    return true
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let state = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    state.isEnabled = false
    state.tag = 1
    menu.addItem(state)
    menu.addItem(.separator())
    let open = NSMenuItem(
      title: Self.localized("Open Minerva"), action: #selector(openWindow), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(
      title: Self.localized("Quit Minerva"),
      action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    menu.delegate = self
    return menu
  }

  func menuWillOpen(_ menu: NSMenu) {
    guard let w = window else { return }
    let state =
      w.overlay
      ? (w.overlayReason == "computer" ? "Using the Mac · Open Minerva to come back" : "Phone connected")
      : w.userOpen ? "Listening on this Mac" : "In the background · the Mac is not listening"
    menu.item(withTag: 1)?.title = Self.localized(state)
  }

  @objc private func openWindow() {
    window?.showNormal()
  }
}
