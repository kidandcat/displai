import AVFoundation
import Carbon.HIToolbox
import Cocoa
import FlutterMacOS
import IOKit.hidsystem
import WebKit
import webview_flutter_wkwebview

/// Minerva's only window. While it is on screen it covers the whole main screen, fully
/// transparent and click-through: Flutter draws on it what the user sees (the full view's
/// panel, the orb, the widgets Minerva pops) and reports their rects, and only there does the
/// window take the mouse ([hitRects]); everywhere else clicks reach the apps below. States:
///   open     the full view, a panel at the left edge (the user moves and resizes it, and it goes
///            back to the left whenever it is full again); the Mac listens and speaks. An
///            ordinary window: the other apps come in front of it, and when the user goes to one
///            it becomes the orb (reason "away") until they come back to Minerva
///   hidden   ordered out; the app keeps running in the background without the Mac's mic
///   overlay  just the orb on the right edge of the screen (and Minerva's widgets), over every app and on
///            every Space, while a phone is connected (reason "phone"), while Minerva works in
///            other apps of the Mac (reason "computer") or while the user is in another app (reason
///            "away"). It never keeps the keyboard: the app the user (or Minerva) works in stays
///            in front. It goes back to open or hidden afterwards.
/// The mute key (the space bar by default) toggles the mic from any app ([MuteKey]).
///
/// Method channel `minerva/window`:
///   Dart → native  state() -> State   setOverlay({on, reason})   show()   hide()
///                  setHitRects([[x, y, w, h]])   setPanel([x, y, w, h])   setOrb([x, y])
///                  contextMenu()   setLanguage({code, save})   systemLanguages() -> [String]
///                  setMuteKey({code, modifiers}) -> MuteKeyStatus   muteKeyStatus() -> MuteKeyStatus
///                  recordMuteKey() -> {code, modifiers, char} or nil   cancelMuteKey()
///                  setTyping(bool)   requestKeyAccess() -> MuteKeyStatus
///   native → Dart  state(State)   openRequested()   (the user asked for the window while it is
///                  the orb)   muteKey()   (the mute key was pressed)   muteKeyStatus(MuteKeyStatus)
/// State: {open, overlay, reason, insets: [left, top, right, bottom] (the menu bar and the Dock),
/// panel: [x, y, w, h], orb: [x, y] or nil}. Rects are in points from the window's top-left.
/// MuteKeyStatus: {accessibility, active} (the permission, and the key works).
class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var audio: VoiceAudio?
  private var computer: ComputerControl?
  private var camera: CameraCapture?
  private var channel: FlutterMethodChannel?
  private let muteKey = MuteKey()
  /// The pending recordMuteKey call.
  private var recording: FlutterResult?

  /// The user has the window open (not closed).
  private(set) var userOpen = false
  private(set) var overlay = false
  /// Why the window is the orb: "phone" or "computer".
  private(set) var overlayReason = "phone"
  /// The last other app in front, given the focus back while the window is the orb.
  private var lastOtherApp: NSRunningApplication?
  /// When the window last came back from the orb to the full view.
  private var fullSince = Date.distantPast
  /// Where the window takes the mouse, from its top-left.
  private var hitRects: [NSRect] = []
  private var hitTimer: Timer?
  /// Set while Minerva posts its own clicks: the window lets the mouse through everywhere.
  var passThroughHolds = 0
  var contextMenu: NSMenu?

  private static let panelKey = "panelFrame"
  private static let orbKey = "orbOrigin"
  /// Where the window was saved while it was a normal window (the panel starts there).
  private static let legacyFrameKey = "NSWindow Frame MinervaMain"

  override func awakeFromNib() {
    if AppDelegate.handOffToRunningInstance() { exit(0) }
    // The engine runs on its own, not when the window first appears: the app may start hidden.
    let engine = FlutterEngine(name: "minerva", project: nil, allowHeadlessExecution: true)
    let flutterViewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    flutterViewController.backgroundColor = .clear
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    audio = VoiceAudio(messenger: engine.binaryMessenger)
    computer = ComputerControl(messenger: engine.binaryMessenger)
    camera = CameraCapture(messenger: engine.binaryMessenger)
    let pages = FlutterMethodChannel(name: "minerva/webview", binaryMessenger: engine.binaryMessenger)
    pages.setMethodCallHandler { [weak flutterViewController] call, result in
      guard let controller = flutterViewController else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "snapshot":
        PageSnapshots.capture(in: controller.view, result)
      case "transparent":
        // The plugin's setBackgroundColor is UIKit only: let the display show through the page.
        if let id = (call.arguments as? NSNumber)?.int64Value,
          let page = FWFWebViewFlutterWKWebViewExternalAPI.webView(
            forIdentifier: id, withPluginRegistry: controller)
        {
          page.setValue(false, forKey: "drawsBackground")
          result(true)
        } else {
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let channel = FlutterMethodChannel(name: "minerva/window", binaryMessenger: engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    self.channel = channel
    muteKey.window = self
    muteKey.onPress = { [weak self] in self?.channel?.invokeMethod("muteKey", arguments: nil) }
    muteKey.onActive = { [weak self] in
      guard let self = self else { return }
      self.channel?.invokeMethod("muteKeyStatus", arguments: self.muteKeyStatus)
    }
    muteKey.start()
    delegate = self
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier
      else { return }
      self?.lastOtherApp = app
      self?.otherAppActivated()
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.appActivated() }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.setFrame(Self.screen.frame, display: true)
      self.notify()
    }
    isReleasedWhenClosed = false
    isRestorable = false
    // Stays a titled window with an invisible title bar: a borderless window swaps the window's
    // frame view, and the Flutter view stops showing after that.
    styleMask = [.titled, .closable, .fullSizeContentView]
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovable = false
    applyLevel()
    // Stays on screen while other apps are in front, and when one of them hides the others.
    hidesOnDeactivate = false
    canHide = false
    ignoresMouseEvents = true
    setFrame(Self.screen.frame, display: false)
    setTitleButtonsHidden()
    engine.run(withEntrypoint: nil)

    super.awakeFromNib()
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "state":
      result(state)
    case "setOverlay":
      if let args = call.arguments as? [String: Any] {
        setOverlay(args["on"] as? Bool ?? false, reason: args["reason"] as? String ?? "phone")
      } else {
        setOverlay(call.arguments as? Bool ?? false)
      }
      result(nil)
    case "show":
      showNormal()
      result(nil)
    case "hide":
      hideWindow()
      result(nil)
    case "setHitRects":
      hitRects = (call.arguments as? [[NSNumber]] ?? []).compactMap(Self.rect)
      updateMousePassThrough()
      result(nil)
    case "setPanel":
      if let r = (call.arguments as? [NSNumber]).flatMap(Self.rect) {
        UserDefaults.standard.set(NSStringFromRect(r), forKey: Self.panelKey)
      }
      result(nil)
    case "setOrb":
      if let p = call.arguments as? [NSNumber], p.count == 2 {
        UserDefaults.standard.set(
          NSStringFromPoint(NSPoint(x: p[0].doubleValue, y: p[1].doubleValue)), forKey: Self.orbKey)
      }
      result(nil)
    case "contextMenu":
      contextMenu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
      result(nil)
    case "setLanguage":
      let args = call.arguments as? [String: Any]
      AppDelegate.setLanguage(args?["code"] as? String, save: args?["save"] as? Bool ?? false)
      result(nil)
    case "systemLanguages":
      result(AppDelegate.systemLanguages)
    case "setMuteKey":
      let args = call.arguments as? [String: Any] ?? [:]
      muteKey.set(
        code: (args["code"] as? NSNumber)?.int64Value ?? Int64(kVK_Space),
        flags: MuteKey.flags((args["modifiers"] as? NSNumber)?.intValue ?? 0))
      result(muteKeyStatus)
    case "muteKeyStatus":
      result(muteKeyStatus)
    case "recordMuteKey":
      recording?(nil)
      recording = result
      muteKey.record { [weak self] code, flags in
        guard let self = self, let done = self.recording else { return }
        self.recording = nil
        done(code.map { ["code": $0, "modifiers": MuteKey.bits(flags), "char": MuteKey.character($0)] })
      }
    case "cancelMuteKey":
      muteKey.record(nil)
      recording?(nil)
      recording = nil
      result(nil)
    case "setTyping":
      muteKey.typing = call.arguments as? Bool ?? false
      result(nil)
    case "requestKeyAccess":
      let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      if !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) {
        result(muteKeyStatus)
        return
      }
      if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
      result(muteKeyStatus)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func rect(_ v: [NSNumber]) -> NSRect? {
    v.count == 4 ? NSRect(x: v[0].doubleValue, y: v[1].doubleValue, width: v[2].doubleValue, height: v[3].doubleValue) : nil
  }

  /// The screen with the menu bar.
  private static var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

  private var state: [String: Any] {
    let s = Self.screen, f = s.frame, v = s.visibleFrame
    var out: [String: Any] = [
      "open": userOpen, "overlay": overlay, "reason": overlayReason,
      "insets": [v.minX - f.minX, f.maxY - v.maxY, f.maxX - v.maxX, v.minY - f.minY],
      "panel": Self.rectList(panelFrame()),
    ]
    if let saved = UserDefaults.standard.string(forKey: Self.orbKey) {
      let p = NSPointFromString(saved)
      out["orb"] = [p.x, p.y]
    }
    return out
  }

  private static func rectList(_ r: NSRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }

  /// The full view's panel, from the window's top-left: where the user left it, else where the
  /// normal window was, else at the left edge of the visible frame, the whole height. Flutter keeps
  /// only its width: the full view always sits at the left (lib/app/overlay_shell.dart).
  private func panelFrame() -> NSRect {
    if let saved = UserDefaults.standard.string(forKey: Self.panelKey) { return NSRectFromString(saved) }
    let s = Self.screen.frame
    if let legacy = UserDefaults.standard.string(forKey: Self.legacyFrameKey) {
      let n = legacy.split(separator: " ").compactMap { Double($0) }
      if n.count >= 4, n[2] >= 480, n[3] >= 360 {
        return NSRect(x: n[0] - s.minX, y: s.maxY - n[1] - n[3], width: n[2], height: n[3])
      }
    }
    let v = Self.screen.visibleFrame
    return NSRect(x: v.minX - s.minX, y: s.maxY - v.maxY, width: min(1100, v.width - 80), height: v.height)
  }

  private func notify() {
    channel?.invokeMethod("state", arguments: state)
  }

  private var muteKeyStatus: [String: Any] {
    ["accessibility": AXIsProcessTrusted(), "active": muteKey.active]
  }

  /// A titled window keeps out of the menu bar; this one covers the whole screen.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

  // ---------------------------------------------------------------- open / hidden

  func showNormal() {
    userOpen = true
    // Minerva is working in another app: the user wants the window back.
    if overlay && overlayReason == "computer" { channel?.invokeMethod("openRequested", arguments: nil) }
    if overlay && overlayReason == "away" {
      setOverlay(false)
      return
    }
    if !overlay {
      NSApp.setActivationPolicy(.regular)
      present()
      makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    notify()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hideWindow()
    return false
  }

  /// The user closes the full view: the window goes away (the orb stays while it is one).
  func hideWindow() {
    userOpen = false
    if overlay && overlayReason == "away" {
      overlay = false
      applyLevel()
    }
    if !overlay { conceal() }
    notify()
  }

  /// On screen: over the whole main screen, taking the mouse only where Flutter draws.
  private func present() {
    setFrame(Self.screen.frame, display: true)
    setTitleButtonsHidden()
    orderFrontRegardless()
    if hitTimer == nil {
      // The cursor is checked against the rects on every frame: the window server only lets a
      // window take the mouse or not as a whole.
      let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.updateMousePassThrough() }
      RunLoop.main.add(t, forMode: .common)
      hitTimer = t
    }
    muteKey.enabled = true
  }

  private func conceal() {
    orderOut(nil)
    hitTimer?.invalidate()
    hitTimer = nil
    muteKey.enabled = false
    NSApp.setActivationPolicy(.accessory)
  }

  /// Takes the mouse while the cursor is over something Flutter drew, lets it through elsewhere.
  /// A press that is held keeps it where it started, so drags are never cut in two.
  func updateMousePassThrough() {
    var ignore = true
    if passThroughHolds == 0 {
      if NSEvent.pressedMouseButtons != 0 { return }
      let m = NSEvent.mouseLocation
      let p = NSPoint(x: m.x - frame.minX, y: frame.maxY - m.y)
      ignore = !hitRects.contains { $0.contains(p) }
    }
    if ignoresMouseEvents != ignore { ignoresMouseEvents = ignore }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { !overlay }

  // ---------------------------------------------------------------- overlay

  func setOverlay(_ on: Bool, reason: String = "phone") {
    if on { overlayReason = reason }
    if on == overlay {
      notify()
      return
    }
    overlay = on
    applyLevel()
    if on && reason == "away" {
      // The user is in another app already; Minerva stays in the Dock and the app switcher, to
      // come back to.
      present()
    } else if on {
      NSApp.setActivationPolicy(.accessory)
      // After the policy switch, which deactivates the app.
      present()
      yieldFocus()
    } else if userOpen {
      fullSince = Date()
      NSApp.setActivationPolicy(.regular)
      present()
      makeKeyAndOrderFront(nil)
      // Back from working in other apps: Minerva comes in front of them.
      if overlayReason != "phone" { NSApp.activate(ignoringOtherApps: true) }
    } else {
      conceal()
    }
    notify()
  }

  /// The orb stays over every app and on every Space, their floating panels too; the full view is
  /// an ordinary window, which the other apps come in front of.
  private func applyLevel() {
    level = overlay ? .statusBar : .normal
    collectionBehavior =
      overlay ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle] : [.managed, .fullScreenAuxiliary]
  }

  /// Another app came in front (the user switched to it, or opened it) with the full view open:
  /// the window becomes the orb, so that app is seen. Minerva's own work in other apps makes it
  /// the orb before it acts; right after the full view comes back, an app Minerva brought up may
  /// still take the front, so that is checked again a moment later.
  private func otherAppActivated() {
    guard userOpen, !overlay else { return }
    let wait = 1 - Date().timeIntervalSince(fullSince)
    if wait > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
        guard let self = self, !NSApp.isActive,
          NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        self.otherAppActivated()
      }
      return
    }
    setOverlay(true, reason: "away")
  }

  /// The user came back to Minerva (the Dock, the app switcher, Spotlight) while it is the orb
  /// because they had gone to another app: the full view comes back. Not for a press on the orb or
  /// a widget, which activates the app too (a tap on the orb brings the full view back from Dart).
  private func appActivated() {
    guard userOpen, overlay, overlayReason == "away" else { return }
    if NSEvent.pressedMouseButtons != 0 {
      let m = NSEvent.mouseLocation
      let p = NSPoint(x: m.x - frame.minX, y: frame.maxY - m.y)
      if hitRects.contains(where: { $0.contains(p) }) { return }
    }
    setOverlay(false)
  }

  /// Gives the keyboard back to the app in front before Minerva, so typing and key presses go
  /// there and not to the orb.
  private func yieldFocus() {
    let me = ProcessInfo.processInfo.processIdentifier
    guard NSApp.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == me else { return }
    var target = lastOtherApp.flatMap { $0.isTerminated ? nil : $0 }
    if target == nil {
      // The owner of the topmost window of another regular app.
      let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
      for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
          let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular
        else { continue }
        target = app
        break
      }
    }
    guard let app = target else { return }
    if #available(macOS 14.0, *) { NSApp.yieldActivation(to: app) }
    app.activate()
  }

  /// Hides the title bar for good: the traffic lights and every view of the frame but the
  /// content (AppKit shows the buttons again when the window is laid out or changes key).
  private func setTitleButtonsHidden() {
    for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      standardWindowButton(b)?.isHidden = true
      standardWindowButton(b)?.alphaValue = 0
    }
    standardWindowButton(.closeButton)?.superview?.isHidden = true
    if let content = contentView, let frameView = content.superview {
      for v in frameView.subviews where v !== content && !v.isHidden {
        v.isHidden = true
        v.alphaValue = 0
      }
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    setTitleButtonsHidden()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    setTitleButtonsHidden()
  }

  func windowDidResize(_ notification: Notification) {
    // AppKit lays the title bar out again once the window has its new frame.
    DispatchQueue.main.async { [weak self] in self?.setTitleButtonsHidden() }
  }

  override func sendEvent(_ event: NSEvent) {
    // Minerva's own clicks are meant for the app below, never for its own window.
    if Self.isMouse(event.type),
      event.cgEvent?.getIntegerValueField(.eventSourceUserData) == ComputerControl.syntheticEventTag
    {
      return
    }
    super.sendEvent(event)
    // A click on the orb or a widget activates Minerva (once the event is handled): hand the
    // keyboard back.
    if overlay && (event.type == .leftMouseUp || event.type == .rightMouseUp) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
        guard let self = self, self.overlay else { return }
        self.yieldFocus()
      }
    }
  }

  private static func isMouse(_ t: NSEvent.EventType) -> Bool {
    [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
     .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel].contains(t)
  }
}

/// The mute key toggles Minerva's mic from any app: the space bar unless the user picked another
/// key, a combo or Caps Lock in the settings. In Minerva's own window a local event monitor takes
/// it (no permission needed); in the other apps a keyboard event tap does (it needs the
/// Accessibility permission Minerva already has for computer use, and Input Monitoring on some
/// systems). A key that types (no ⌘ or ⌃) works only while Minerva is on screen, and not while the
/// user is typing in a text field: Minerva's own ([typing], told by Flutter, or a web page's) or
/// the one of the app in front. A combo with ⌘ or ⌃, and Caps Lock, work everywhere, also while
/// Minerva is hidden. Caps Lock is turned off again after each press, so it never stays on.
/// Minerva's own key presses are tagged and go through. The tap runs on its own thread, so the
/// keyboard never waits for the UI.
final class MuteKey {
  /// Called on the main thread on each press taken.
  var onPress: (() -> Void)?
  /// Called on the main thread once the tap works (the permission may come later).
  var onActive: (() -> Void)?
  /// Minerva's window, to tell whether a web page in it has the keyboard.
  weak var window: NSWindow?

  static let capsLock = Int64(kVK_CapsLock)
  /// The modifiers a combo is made of (not fn, which arrow and function keys carry on their own).
  static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

  /// Minerva is on screen.
  var enabled: Bool {
    get { locked { on } }
    set {
      locked { on = newValue }
      if newValue { install() }
    }
  }

  /// A text field of Minerva's own has the keyboard focus. Main thread.
  var typing = false

  /// The tap is in place: the key works in the other apps.
  var active: Bool { locked { tap != nil } }

  private let lock = NSLock()
  private var on = false
  private var code = Int64(kVK_Space)
  private var flags: CGEventFlags = []
  /// Caps Lock can be turned off from here (else each of its toggles counts as a press).
  private var capsReset = true
  private var tap: CFMachPort?
  private var thread: Thread?
  private var retrying = false
  /// The key whose press the tap took: its repeats and its release are taken too (tap thread only).
  private var taken: Int64?
  /// The same for the local monitor (main thread).
  private var takenHere: Int64?
  private var monitor: Any?
  private var recorder: ((Int64?, CGEventFlags) -> Void)? {
    didSet { locked { recordingNow = recorder != nil } }
  }
  /// [recorder] is set, for the tap thread.
  private var recordingNow = false

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  /// Caps Lock, and combos with ⌘ or ⌃, which type nothing: they work in every app, at any time.
  private static func isGlobal(_ code: Int64, _ flags: CGEventFlags) -> Bool {
    code == capsLock || !flags.intersection([.maskCommand, .maskControl]).isEmpty
  }

  /// Starts listening in Minerva's own window. Main thread.
  func start() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
      self?.local(e) ?? e
    }
  }

  /// The key: a virtual key code ([kVK_Space], [capsLock]…) and [modifiers]. Main thread.
  func set(code: Int64, flags: CGEventFlags) {
    let f = flags.intersection(Self.modifiers)
    locked {
      self.code = code
      self.flags = f
    }
    if code == Self.capsLock {
      let ok = Self.capsLockOff()
      locked { capsReset = ok }
    }
    if Self.isGlobal(code, f) { install() }
  }

  /// Hands the next key or combo pressed in Minerva's window to [done] instead of to the window
  /// (nil for Escape, which cancels); nil stops waiting. Main thread.
  func record(_ done: ((Int64?, CGEventFlags) -> Void)?) {
    recorder = done
  }

  private var wanted: Bool { locked { on || Self.isGlobal(code, flags) } }

  private func install() {
    guard thread == nil else { return }
    guard AXIsProcessTrusted() else { return retryLater() }
    let t = Thread { [weak self] in
      guard let self = self else { return }
      let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)
      guard let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: { _, type, event, info in
          Unmanaged<MuteKey>.fromOpaque(info!).takeUnretainedValue().handle(type, event)
        },
        userInfo: Unmanaged.passUnretained(self).toOpaque())
      else {
        DispatchQueue.main.async {
          self.thread = nil
          // Accessibility is not always enough to see the keyboard: ask for Input Monitoring too.
          if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
          self.retryLater()
        }
        return
      }
      self.locked { self.tap = port }
      DispatchQueue.main.async { self.onActive?() }
      CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
      CFRunLoopRun()
    }
    t.name = "minerva.mutekey"
    thread = t
    t.start()
  }

  /// Tries again in a while: the user may still grant the permission.
  private func retryLater() {
    guard !retrying else { return }
    retrying = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      guard let self = self else { return }
      self.retrying = false
      if self.wanted { self.install() }
    }
  }

  private static var minervaInFront: Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
  }

  // The tap (its own thread): the other apps, and the global keys everywhere.

  private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap = locked({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
      return pass
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    if type == .flagsChanged {
      if code == Self.capsLock { capsLockToggled(on: event.flags.contains(.maskAlphaShift)) }
      return pass
    }
    if type == .keyUp {
      guard code == taken else { return pass }
      taken = nil
      return nil
    }
    if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return code == taken ? nil : pass }
    taken = nil
    guard event.getIntegerValueField(.eventSourceUserData) != ComputerControl.syntheticEventTag else { return pass }
    let (key, keyFlags, on, recording) = locked { (self.code, self.flags, self.on, recordingNow) }
    // The key being recorded goes to Minerva's window.
    if recording && Self.minervaInFront { return pass }
    guard code == key, event.flags.intersection(Self.modifiers) == keyFlags, key != Self.capsLock else { return pass }
    if !Self.isGlobal(key, keyFlags) {
      // In Minerva's window the local monitor decides.
      guard on, !Self.minervaInFront, !Self.typingInFocusedField() else { return pass }
    }
    taken = code
    DispatchQueue.main.async { [weak self] in self?.onPress?() }
    return nil
  }

  /// Caps Lock went on or off (tap thread). Each press counts while Caps Lock is the key; once
  /// Minerva turns it off after a press, only the presses that turn it on are the user's.
  private func capsLockToggled(on capsOn: Bool) {
    let (key, reset) = locked { (code, capsReset) }
    guard key == Self.capsLock, capsOn || !reset else { return }
    DispatchQueue.main.async { [weak self] in
      // While recording, the local monitor has it.
      guard let self = self, self.recorder == nil || !Self.minervaInFront else { return }
      self.capsPressed()
    }
  }

  private func capsPressed() {
    let ok = Self.capsLockOff()
    locked { capsReset = ok }
    onPress?()
  }

  // The local monitor (main thread): Minerva's own window.

  private func local(_ e: NSEvent) -> NSEvent? {
    let code = Int64(e.keyCode)
    let pressed = e.cgEvent?.flags.intersection(Self.modifiers) ?? []
    if e.type == .flagsChanged {
      guard code == Self.capsLock else { return e }
      if let done = recorder {
        recorder = nil
        done(Self.capsLock, [])
      } else if !active, locked({ self.code }) == Self.capsLock,
        e.modifierFlags.contains(.capsLock) || !locked({ capsReset })
      {
        capsPressed()
      }
      return e
    }
    if e.type == .keyUp {
      guard code == takenHere else { return e }
      takenHere = nil
      return nil
    }
    if e.isARepeat { return code == takenHere ? nil : e }
    takenHere = nil
    if e.cgEvent?.getIntegerValueField(.eventSourceUserData) == ComputerControl.syntheticEventTag { return e }
    if let done = recorder {
      recorder = nil
      takenHere = code
      done(code == Int64(kVK_Escape) && pressed.isEmpty ? nil : code, pressed)
      return nil
    }
    let (key, keyFlags) = locked { (self.code, self.flags) }
    guard code == key, pressed == keyFlags, key != Self.capsLock else { return e }
    // The tap already took a global key.
    if Self.isGlobal(key, keyFlags) && active { return e }
    if !Self.isGlobal(key, keyFlags) && (typing || webPageHasKeyboard) { return e }
    takenHere = code
    onPress?()
    return nil
  }

  /// A custom page (a web view) on the display has the keyboard: its keys are its own.
  private var webPageHasKeyboard: Bool {
    var v = window?.firstResponder as? NSView
    while let view = v {
      if view is WKWebView { return true }
      v = view.superview
    }
    return false
  }

  /// Turns Caps Lock off through the HID system; false when macOS does not let it.
  static func capsLockOff() -> Bool {
    let service = IOServiceGetMatchingService(mach_port_t(MACH_PORT_NULL), IOServiceMatching(kIOHIDSystemClass))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    var connect: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS
    else { return false }
    defer { IOServiceClose(connect) }
    return IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false) == KERN_SUCCESS
  }

  /// [modifiers] as Dart sends them: 1 ⌘, 2 ⌃, 4 ⌥, 8 ⇧.
  static func flags(_ bits: Int) -> CGEventFlags {
    var f: CGEventFlags = []
    if bits & 1 != 0 { f.insert(.maskCommand) }
    if bits & 2 != 0 { f.insert(.maskControl) }
    if bits & 4 != 0 { f.insert(.maskAlternate) }
    if bits & 8 != 0 { f.insert(.maskShift) }
    return f
  }

  static func bits(_ f: CGEventFlags) -> Int {
    (f.contains(.maskCommand) ? 1 : 0) | (f.contains(.maskControl) ? 2 : 0)
      | (f.contains(.maskAlternate) ? 4 : 0) | (f.contains(.maskShift) ? 8 : 0)
  }

  /// What [code] types on the current keyboard layout without modifiers, upper-cased; empty for
  /// keys that type nothing visible. Main thread (Text Input Sources).
  static func character(_ code: Int64) -> String {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return "" }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    return data.withUnsafeBytes { raw -> String in
      guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "" }
      var dead: UInt32 = 0
      var chars = [UniChar](repeating: 0, count: 4)
      var len = 0
      guard UCKeyTranslate(
        layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars) == noErr
      else { return "" }
      let s = String(utf16CodeUnits: chars, count: len)
      return s.unicodeScalars.allSatisfy({ $0.properties.isWhitespace || $0.value < 32 || $0.value == 127 })
        ? "" : s.uppercased()
    }
  }

  private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

  /// The focused element of the app in front takes text (a field, a text view, a terminal, an
  /// editable web page).
  private static func typingInFocusedField() -> Bool {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.1)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &v) == .success,
      let v = v, CFGetTypeID(v) == AXUIElementGetTypeID()
    else { return false }
    let el = v as! AXUIElement
    AXUIElementSetMessagingTimeout(el, 0.1)
    var role: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) == .success,
      let r = role as? String, textRoles.contains(r)
    {
      return true
    }
    var settable: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(el, kAXSelectedTextRangeAttribute as CFString, &settable) == .success
      && settable.boolValue
  }
}

/// Full-duplex audio with macOS voice processing (echo cancellation).
///
/// Capture and playback go through the same AVAudioEngine so the canceller has the
/// speaker signal as its reference; that is what lets the user interrupt by voice.
///
/// Method channel `minerva/audio`:
///   start({playRate})   -> String (formats)  starts the engine
///   play(Float32List)   schedules mono samples at playRate
///   stop()              drops everything queued/playing
///   shutdown()          stops the engine and releases the mic (start again to resume)
/// Event channel `minerva/audio_events` (maps):
///   {t: "mic", d: Float32List}           echo-cancelled mic audio, 16 kHz mono
///   {t: "out", d: Float32List, sr: Int}  audio actually being played (for the presence animation)
///   {t: "idle"}                          playback queue drained
final class VoiceAudio: NSObject, FlutterStreamHandler {
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var sink: FlutterEventSink?

  private var engine: AVAudioEngine?
  private let player = AVAudioPlayerNode()
  private var playFormat: AVAudioFormat?
  private let lock = NSLock()
  private var pending = 0
  private var generation = 0

  init(messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "minerva/audio", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "minerva/audio_events", binaryMessenger: messenger)
    super.init()
    events.setStreamHandler(self)
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    sink = eventSink
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func send(_ event: [String: Any]) {
    DispatchQueue.main.async { [weak self] in self?.sink?(event) }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      let args = call.arguments as? [String: Any] ?? [:]
      let rate = (args["playRate"] as? NSNumber)?.doubleValue ?? 44100
      do {
        result(try start(playRate: rate))
      } catch {
        result(FlutterError(code: "audio_start", message: "\(error)", details: nil))
      }
    case "play":
      guard let data = call.arguments as? FlutterStandardTypedData else {
        result(FlutterError(code: "bad_args", message: "expected Float32List", details: nil))
        return
      }
      play(data.data)
      result(nil)
    case "stop":
      stopPlayback()
      result(nil)
    case "shutdown":
      shutdown()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(playRate: Double) throws -> String {
    if engine != nil { return "already started" }
    let engine = AVAudioEngine()
    let input = engine.inputNode
    // Touch the output graph before enabling voice processing; otherwise the
    // voice-processing output unit can fail to initialize (-10875).
    _ = engine.outputNode
    _ = engine.mainMixerNode
    try input.setVoiceProcessingEnabled(true)
    if #available(macOS 14.0, *) {
      input.voiceProcessingOtherAudioDuckingConfiguration =
        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
    }

    let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: playRate, channels: 1,
                                   interleaved: false)!
    self.playFormat = playFormat
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: playFormat)

    // Mic: the voice-processed input has several channels; channel 0 is the processed mic.
    let inFormat = input.outputFormat(forBus: 0)
    let monoIn = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 1,
                               interleaved: false)!
    let micFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                                  interleaved: false)!
    guard let converter = AVAudioConverter(from: monoIn, to: micFormat) else {
      throw NSError(domain: "minerva", code: 1, userInfo: [NSLocalizedDescriptionKey: "no converter for \(inFormat)"])
    }
    input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
      let n = buf.frameLength
      guard n > 0, let src = buf.floatChannelData else { return }
      let mono = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: n)!
      mono.frameLength = n
      memcpy(mono.floatChannelData![0], src[0], Int(n) * 4)
      let cap = AVAudioFrameCount(Double(n) * 16000 / inFormat.sampleRate) + 64
      let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: cap)!
      var given = false
      var err: NSError?
      converter.convert(to: out, error: &err) { _, status in
        if given {
          status.pointee = .noDataNow
          return nil
        }
        given = true
        status.pointee = .haveData
        return mono
      }
      if out.frameLength == 0 { return }
      let data = Data(bytes: out.floatChannelData![0], count: Int(out.frameLength) * 4)
      self?.send(["t": "mic", "d": FlutterStandardTypedData(float32: data)])
    }

    // What is actually being played, for the presence animation.
    player.installTap(onBus: 0, bufferSize: 2048, format: playFormat) { [weak self] buf, _ in
      guard let self = self, self.isPlaying, let ch = buf.floatChannelData else { return }
      let data = Data(bytes: ch[0], count: Int(buf.frameLength) * 4)
      self.send(["t": "out", "d": FlutterStandardTypedData(float32: data), "sr": Int(playRate)])
    }

    engine.prepare()
    try engine.start()
    player.play()
    self.engine = engine
    return "in=\(inFormat.sampleRate)Hz/\(inFormat.channelCount)ch play=\(playRate)Hz"
  }

  private var isPlaying: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pending > 0
  }

  private func play(_ data: Data) {
    guard let playFormat = playFormat, engine != nil else { return }
    let count = data.count / 4
    if count == 0 { return }
    let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(count))!
    buf.frameLength = AVAudioFrameCount(count)
    _ = data.withUnsafeBytes { raw in memcpy(buf.floatChannelData![0], raw.baseAddress!, count * 4) }
    lock.lock()
    pending += 1
    let gen = generation
    lock.unlock()
    player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      guard let self = self else { return }
      self.lock.lock()
      if gen == self.generation { self.pending -= 1 }
      let idle = gen == self.generation && self.pending == 0
      self.lock.unlock()
      if idle { self.send(["t": "idle"]) }
    }
  }

  private func stopPlayback() {
    lock.lock()
    generation += 1
    pending = 0
    lock.unlock()
    player.stop()
    player.play()
    send(["t": "idle"])
  }

  private func shutdown() {
    guard let engine = engine else { return }
    lock.lock()
    generation += 1
    pending = 0
    lock.unlock()
    player.stop()
    player.removeTap(onBus: 0)
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    try? engine.inputNode.setVoiceProcessingEnabled(false)
    engine.detach(player)
    self.engine = nil
    playFormat = nil
    send(["t": "idle"])
  }
}

/// Snapshots of the custom pages (WKWebViews) on the display: Flutter cannot capture platform
/// views, so the display's snapshot tool draws these over its own capture.
enum PageSnapshots {
  /// Replies with [{x, y, w, h, png}], frames in points from the top-left of [root].
  static func capture(in root: NSView, _ result: @escaping FlutterResult) {
    var pages: [WKWebView] = []
    func walk(_ v: NSView) {
      if let w = v as? WKWebView {
        if !w.isHiddenOrHasHiddenAncestor && w.bounds.width > 0 && w.bounds.height > 0 { pages.append(w) }
        return
      }
      v.subviews.forEach(walk)
    }
    walk(root)
    if pages.isEmpty {
      result([])
      return
    }
    var out: [[String: Any]] = []
    var left = pages.count
    for page in pages {
      var r = page.convert(page.bounds, to: root)
      if !root.isFlipped { r.origin.y = root.bounds.height - r.maxY }
      page.takeSnapshot(with: nil) { image, _ in
        if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
        {
          out.append([
            "x": r.origin.x, "y": r.origin.y, "w": r.width, "h": r.height,
            "png": FlutterStandardTypedData(bytes: png),
          ])
        }
        left -= 1
        if left == 0 { result(out) }
      }
    }
  }
}

