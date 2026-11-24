import Cocoa
import FlutterMacOS

/// Minerva runs as a background service: closing the window hides it (the Mac stops listening)
/// but the app keeps running, so the phone remote, workers and routines keep working. A menu bar
/// item opens the window again or quits. Started with `--background` (the login LaunchAgent), it
/// starts hidden. Its texts are in en.lproj / es.lproj (Localizable.strings), picked by the
/// macOS preferred languages like the Flutter UI's.
@main
class AppDelegate: FlutterAppDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem?
  private var activity: NSObjectProtocol?

  static let showNotification = Notification.Name("com.kidandcat.minerva.show")

  private var window: MainFlutterWindow? { mainFlutterWindow as? MainFlutterWindow }

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
      title: NSLocalizedString("Open Minerva", comment: "Menu item"), action: #selector(openWindow), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(
      title: NSLocalizedString("Quit Minerva", comment: "Menu item"),
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
    menu.item(withTag: 1)?.title = Bundle.main.localizedString(forKey: state, value: nil, table: nil)
  }

  @objc private func openWindow() {
    window?.showNormal()
  }
}
