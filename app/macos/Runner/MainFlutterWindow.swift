import AVFoundation
import Carbon.HIToolbox
import Cocoa
import FlutterMacOS
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
///   overlay  just the orb in the top-right corner (and Minerva's widgets), over every app and on
///            every Space, while a phone is connected (reason "phone"), while Minerva works in
///            other apps of the Mac (reason "computer") or while the user is in another app (reason
///            "away"). It never keeps the keyboard: the app the user (or Minerva) works in stays
///            in front. It goes back to open or hidden afterwards.
/// While the window is on screen the space bar toggles the mic from any app ([SpaceKey]).
///
/// Method channel `minerva/window`:
///   Dart → native  state() -> State   setOverlay({on, reason})   show()   hide()
///                  setHitRects([[x, y, w, h]])   setPanel([x, y, w, h])   setOrb([x, y])
///                  contextMenu()   setLanguage({code, save})   systemLanguages() -> [String]
///   native → Dart  state(State)   openRequested()   (the user asked for the window while it is
///                  the orb)   space()   (the space bar was pressed in another app)
/// State: {open, overlay, reason, insets: [left, top, right, bottom] (the menu bar and the Dock),
/// panel: [x, y, w, h], orb: [x, y] or nil}. Rects are in points from the window's top-left.
class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var audio: VoiceAudio?
  private var computer: ComputerControl?
  private var channel: FlutterMethodChannel?
  private let spaceKey = SpaceKey()

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
    spaceKey.onPress = { [weak self] in self?.channel?.invokeMethod("space", arguments: nil) }
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
    spaceKey.enabled = true
  }

  private func conceal() {
    orderOut(nil)
    hitTimer?.invalidate()
    hitTimer = nil
    spaceKey.enabled = false
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

/// The space bar toggles Minerva's mic from any app while Minerva is on screen: a keyboard event
/// tap (it needs the Accessibility permission Minerva already has for computer use) takes a bare
/// space press away from the app in front, unless the user is typing in a text field there or
/// Minerva itself is in front (Flutter handles it then). Minerva's own key presses are tagged and
/// go through. The tap runs on its own thread, so the keyboard never waits for the UI.
final class SpaceKey {
  /// Called on the main thread on each press taken.
  var onPress: (() -> Void)?

  var enabled: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return on
    }
    set {
      lock.lock()
      on = newValue
      lock.unlock()
      if newValue { install() }
    }
  }

  private let lock = NSLock()
  private var on = false
  private var tap: CFMachPort?
  private var thread: Thread?
  /// The last space press was taken: its repeats and its release are taken too.
  private var taking = false

  private func install() {
    guard thread == nil, AXIsProcessTrusted() else { return }
    let t = Thread { [weak self] in
      guard let self = self else { return }
      let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
      guard let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: { _, type, event, info in
          Unmanaged<SpaceKey>.fromOpaque(info!).takeUnretainedValue().handle(type, event)
        },
        userInfo: Unmanaged.passUnretained(self).toOpaque())
      else {
        DispatchQueue.main.async { self.thread = nil }
        return
      }
      self.tap = port
      CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
      CFRunLoopRun()
    }
    t.name = "minerva.space"
    thread = t
    t.start()
  }

  private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return pass
    }
    guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Space) else { return pass }
    if type == .keyUp {
      let took = taking
      taking = false
      return took ? nil : pass
    }
    if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return taking ? nil : pass }
    taking = false
    guard enabled,
      event.getIntegerValueField(.eventSourceUserData) != ComputerControl.syntheticEventTag,
      event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty,
      NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      !Self.typingInFocusedField()
    else { return pass }
    taking = true
    DispatchQueue.main.async { [weak self] in self?.onPress?() }
    return nil
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

