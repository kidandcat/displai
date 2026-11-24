import AVFoundation
import Cocoa
import FlutterMacOS
import WebKit
import webview_flutter_wkwebview

/// Minerva's only window, in one of three states:
///   open     the normal window; the Mac listens and speaks
///   hidden   closed or minimized; the app keeps running in the background without the Mac's mic
///   overlay  a small round orb, always on top in a corner of the screen, while a phone is
///            connected (reason "phone") or while Minerva works in other apps of the Mac (reason
///            "computer"); drag it to move it, click it to mute. The orb never keeps the keyboard:
///            the app the user (or Minerva) works in stays in front. It goes back to open or
///            hidden afterwards.
///
/// Method channel `minerva/window`:
///   Dart → native  state() -> {open, overlay}   setOverlay({on, reason})   show()
///                  setLanguage({code, save})   systemLanguages() -> [String]
///   native → Dart  state({open, overlay})       tap()   (the overlay orb was clicked)
///                  openRequested()   (the user asked for the window while it is the orb)
class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var audio: VoiceAudio?
  private var computer: ComputerControl?
  private var channel: FlutterMethodChannel?

  /// The user has the window open (not closed or minimized).
  private(set) var userOpen = false
  private(set) var overlay = false
  /// Why the window is the orb: "phone" or "computer".
  private(set) var overlayReason = "phone"
  /// The last other app in front, given the focus back while the window is the orb.
  private var lastOtherApp: NSRunningApplication?
  private var normalFrame: NSRect?
  /// Set while switching to or from the overlay: the frames the window goes through are not saved.
  private var switching = false
  private var dragStart: (mouse: NSPoint, origin: NSPoint)?
  private var dragged = false
  /// Views of the window frame (the title bar) hidden while the window is the orb.
  private var hiddenFrameViews: [NSView] = []
  var contextMenu: NSMenu?

  static let overlaySize: CGFloat = 132
  private static let overlayOriginKey = "overlayOrigin"
  private static let frameName = "MinervaMain"
  private static let minNormalSize = NSSize(width: 480, height: 360)

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
    delegate = self
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier
      else { return }
      self?.lastOtherApp = app
    }
    isReleasedWhenClosed = false
    // The normal frame is saved by us, never the overlay's (macOS restoration would bring back
    // whatever the window last was).
    isRestorable = false
    let nibFrame = frame
    setFrameUsingName(Self.frameName)
    if !Self.isNormalSize(frame) {
      setFrame(nibFrame, display: false)
      center()
    }
    minSize = Self.minNormalSize
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

  private var state: [String: Bool] { ["open": userOpen, "overlay": overlay] }

  private func notify() {
    channel?.invokeMethod("state", arguments: state)
  }

  // ---------------------------------------------------------------- open / hidden

  func showNormal() {
    userOpen = true
    // Minerva is working in another app: the user wants the window back.
    if overlay && overlayReason == "computer" { channel?.invokeMethod("openRequested", arguments: nil) }
    if !overlay {
      NSApp.setActivationPolicy(.regular)
      if isMiniaturized { deminiaturize(nil) }
      makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    notify()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    userOpen = false
    orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
    notify()
    return false
  }

  func windowDidMove(_ notification: Notification) {
    saveNormalFrame()
  }

  func windowDidResize(_ notification: Notification) {
    saveNormalFrame()
  }

  private func saveNormalFrame() {
    if overlay || switching || !Self.isNormalSize(frame) { return }
    saveFrame(usingName: Self.frameName)
  }

  private static func isNormalSize(_ r: NSRect) -> Bool {
    r.width >= minNormalSize.width && r.height >= minNormalSize.height
  }

  func windowDidMiniaturize(_ notification: Notification) {
    userOpen = false
    notify()
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    if overlay { return }
    userOpen = true
    notify()
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { !overlay }

  // ---------------------------------------------------------------- overlay

  func setOverlay(_ on: Bool, reason: String = "phone") {
    if on { overlayReason = reason }
    if on == overlay { return }
    overlay = on
    switching = true
    defer { switching = false }
    if on {
      if isMiniaturized { deminiaturize(nil) }
      if Self.isNormalSize(frame) { normalFrame = frame }
      minSize = NSSize(width: Self.overlaySize, height: Self.overlaySize)
      // Stays a titled window with an invisible title bar: switching to a borderless window
      // swaps the window's frame view, and the Flutter view stops showing after that.
      styleMask = [.titled, .fullSizeContentView]
      titlebarAppearsTransparent = true
      titleVisibility = .hidden
      setTitleButtonsHidden(true)
      isOpaque = false
      backgroundColor = .clear
      hasShadow = false
      // The orb draws no opaque pixel, and the window server lets the mouse through fully
      // transparent ones: the whole square takes the user's clicks instead.
      ignoresMouseEvents = false
      level = .floating
      collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
      setFrame(overlayFrame(), display: true)
      NSApp.setActivationPolicy(.accessory)
      orderFrontRegardless()
      yieldFocus()
      // AppKit lays the title bar out again once the window has its new frame.
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.overlay else { return }
        self.setTitleButtonsHidden(true)
      }
    } else {
      styleMask = [.titled, .closable, .miniaturizable, .resizable]
      titlebarAppearsTransparent = false
      titleVisibility = .visible
      setTitleButtonsHidden(false)
      isOpaque = true
      backgroundColor = .windowBackgroundColor
      hasShadow = true
      level = .normal
      collectionBehavior = []
      minSize = Self.minNormalSize
      if let f = normalFrame { setFrame(f, display: true) }
      if userOpen {
        NSApp.setActivationPolicy(.regular)
        makeKeyAndOrderFront(nil)
        // Back from working in other apps: the window comes in front of them.
        if overlayReason == "computer" { NSApp.activate(ignoringOtherApps: true) }
      } else {
        orderOut(nil)
      }
    }
    notify()
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

  private func setTitleButtonsHidden(_ hidden: Bool) {
    for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      standardWindowButton(b)?.isHidden = hidden
      standardWindowButton(b)?.alphaValue = hidden ? 0 : 1
    }
    // AppKit shows the buttons again when the window stops being key or is laid out (the orb gives
    // the keyboard away): hide the whole title bar too, every view of the frame but the content
    // (its alpha stays where it is set).
    standardWindowButton(.closeButton)?.superview?.isHidden = hidden
    if hidden, let content = contentView, let frameView = content.superview {
      for v in frameView.subviews where v !== content && !v.isHidden {
        v.isHidden = true
        v.alphaValue = 0
        hiddenFrameViews.append(v)
      }
    } else if !hidden {
      for v in hiddenFrameViews {
        v.isHidden = false
        v.alphaValue = 1
      }
      hiddenFrameViews.removeAll()
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    if overlay { setTitleButtonsHidden(true) }
  }

  func windowDidBecomeKey(_ notification: Notification) {
    if overlay { setTitleButtonsHidden(true) }
  }

  /// Top-right corner of the main screen (where the orb sits in the normal window), or where the
  /// user last dragged it.
  private func overlayFrame() -> NSRect {
    let size = NSSize(width: Self.overlaySize, height: Self.overlaySize)
    if let saved = UserDefaults.standard.string(forKey: Self.overlayOriginKey) {
      let rect = NSRect(origin: NSPointFromString(saved), size: size)
      if NSScreen.screens.contains(where: { $0.visibleFrame.contains(rect) }) { return rect }
    }
    let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    return NSRect(origin: NSPoint(x: v.maxX - size.width - 20, y: v.maxY - size.height - 20), size: size)
  }

  /// In overlay mode the window handles the mouse itself: a drag moves it, a click is a tap
  /// (Flutter's own gestures cannot tell them apart while the window follows the pointer).
  override func sendEvent(_ event: NSEvent) {
    guard overlay else {
      super.sendEvent(event)
      return
    }
    // Minerva's own clicks are meant for the app below the orb, never for the orb itself.
    if Self.isMouse(event.type),
      event.cgEvent?.getIntegerValueField(.eventSourceUserData) == ComputerControl.syntheticEventTag
    {
      return
    }
    switch event.type {
    case .leftMouseDown:
      dragStart = (NSEvent.mouseLocation, frame.origin)
      dragged = false
    case .leftMouseDragged:
      guard let start = dragStart else { return }
      let p = NSEvent.mouseLocation
      let dx = p.x - start.mouse.x, dy = p.y - start.mouse.y
      if !dragged && hypot(dx, dy) < 3 { return }
      dragged = true
      setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    case .leftMouseUp:
      if dragStart == nil { return }
      dragStart = nil
      if dragged {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.overlayOriginKey)
      } else {
        channel?.invokeMethod("tap", arguments: nil)
      }
      // A click on the orb activates Minerva (once the event is handled): hand the keyboard back.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
        guard let self = self, self.overlay else { return }
        self.yieldFocus()
      }
    case .rightMouseDown:
      if let menu = contextMenu, let view = contentView {
        NSMenu.popUpContextMenu(menu, with: event, for: view)
      }
    case .rightMouseUp, .rightMouseDragged:
      return
    default:
      super.sendEvent(event)
    }
  }

  private static func isMouse(_ t: NSEvent.EventType) -> Bool {
    [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
     .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel].contains(t)
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

