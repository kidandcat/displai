import ApplicationServices
import Carbon.HIToolbox
import Cocoa
import FlutterMacOS
import ScreenCaptureKit

/// Computer use for the brain: see the screen, read the accessibility tree, click, type, press keys,
/// scroll, open and activate apps.
///
/// All coordinates are global screen points with the origin at the top-left of the main display
/// (the space used by CGEvent, CGWindowList and the AX API).
///
/// Method channel `minerva/computer`:
///   permissions / requestPermissions        -> {accessibility, screen}
///   apps                                    -> [{name, pid, bundleId, active}]
///   windows                                 -> [{id, pid, app, title, x, y, w, h}]
///   screenshot {windowId?}                  -> {png, width, height, originX, originY, scale}
///   tree {pid?, maxNodes}                   -> {text, count, app, pid}
///   elementAt {x, y}                        -> {line, app, pid}  (nil when nothing is there)
///   click {index? | x, y, button, count}    -> String
///   type {text, index?}                     -> String
///   key {combo}                             -> String
///   scroll {dx, dy, x?, y?}                 -> String
///   open {target}                           -> String
///   activate {pid}                          -> String
final class ComputerControl: NSObject {
  private let channel: FlutterMethodChannel?
  /// AX and event work runs here, off the main thread; it also guards [cache].
  private let queue = DispatchQueue(label: "minerva.computer")
  /// Elements of the last `tree`, by the index printed next to them.
  private var cache: [Int: AXUIElement] = [:]

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "minerva/computer", binaryMessenger: messenger)
    super.init()
    channel?.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  /// For standalone use (verification scripts) without Flutter.
  override init() {
    channel = nil
    super.init()
  }

  // MARK: - Dispatch

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
    if call.method == "screenshot" {
      screenshot(windowId: (args["windowId"] as? NSNumber)?.uint32Value) { reply($0) }
      return
    }
    queue.async { [weak self] in
      guard let self = self else { return }
      do {
        reply(try self.run(call.method, args))
      } catch let e as ComputerError {
        reply(FlutterError(code: e.code, message: e.message, details: nil))
      } catch {
        reply(FlutterError(code: "failed", message: "\(error)", details: nil))
      }
    }
  }

  /// Runs a synchronous method on the caller's thread. Throws [ComputerError].
  func run(_ method: String, _ args: [String: Any]) throws -> Any? {
    func num(_ k: String) -> Double? { (args[k] as? NSNumber)?.doubleValue }
    func int(_ k: String) -> Int? { (args[k] as? NSNumber)?.intValue }
    func str(_ k: String) -> String? { args[k] as? String }
    switch method {
    case "permissions":
      return permissions()
    case "requestPermissions":
      return requestPermissions()
    case "apps":
      return apps()
    case "windows":
      return windows()
    case "tree":
      return try tree(pid: int("pid").map { pid_t($0) }, maxNodes: int("maxNodes") ?? 300)
    case "elementAt":
      guard let x = num("x"), let y = num("y") else { throw ComputerError.badArgs("x and y are required") }
      return try elementAt(CGPoint(x: x, y: y))
    case "click":
      let button = str("button") == "right" ? CGMouseButton.right : CGMouseButton.left
      let count = max(1, min(3, int("count") ?? 1))
      if let index = int("index") { return try click(index: index, button: button, count: count) }
      guard let x = num("x"), let y = num("y") else { throw ComputerError.badArgs("index or x,y is required") }
      return try click(at: CGPoint(x: x, y: y), button: button, count: count)
    case "type":
      guard let text = str("text") else { throw ComputerError.badArgs("text is required") }
      return try type(text, index: int("index"))
    case "key":
      guard let combo = str("combo") else { throw ComputerError.badArgs("combo is required") }
      return try key(combo)
    case "scroll":
      var at: CGPoint?
      if let x = num("x"), let y = num("y") { at = CGPoint(x: x, y: y) }
      return try scroll(dx: int("dx") ?? 0, dy: int("dy") ?? 0, at: at)
    case "open":
      guard let target = str("target"), !target.isEmpty else { throw ComputerError.badArgs("target is required") }
      return try open(target)
    case "activate":
      guard let pid = int("pid") else { throw ComputerError.badArgs("pid is required") }
      return try activate(pid_t(pid))
    default:
      throw ComputerError(code: "not_implemented", message: "unknown method \(method)")
    }
  }

  // MARK: - Permissions

  func permissions() -> [String: Bool] {
    ["accessibility": AXIsProcessTrusted(), "screen": CGPreflightScreenCaptureAccess()]
  }

  func requestPermissions() -> [String: Bool] {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let ax = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    var screen = CGPreflightScreenCaptureAccess()
    if !screen { screen = CGRequestScreenCaptureAccess() }
    return ["accessibility": ax, "screen": screen]
  }

  private func requireAccessibility() throws {
    if !AXIsProcessTrusted() { throw ComputerError.noAccessibility }
  }

  // MARK: - Apps and windows

  private static let ownPid = ProcessInfo.processInfo.processIdentifier

  func apps() -> [[String: Any]] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && $0.processIdentifier != Self.ownPid }
      .map {
        [
          "name": $0.localizedName ?? "",
          "pid": Int($0.processIdentifier),
          "bundleId": $0.bundleIdentifier ?? "",
          "active": $0.isActive,
        ]
      }
  }

  /// On-screen windows of regular apps, front to back.
  func windows() -> [[String: Any]] {
    let regular = Dictionary(
      NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && $0.processIdentifier != Self.ownPid }
        .map { ($0.processIdentifier, $0.localizedName ?? "") },
      uniquingKeysWith: { a, _ in a })
    guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]]
    else { return [] }
    var out: [[String: Any]] = []
    for w in info {
      guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, let app = regular[pid],
        (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let id = (w[kCGWindowNumber as String] as? NSNumber)?.intValue,
        let bounds = w[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: bounds),
        rect.width >= 80, rect.height >= 50
      else { continue }
      if let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha < 0.05 { continue }
      out.append([
        "id": id, "pid": Int(pid), "app": app, "title": w[kCGWindowName as String] as? String ?? "",
        "x": Int(rect.minX), "y": Int(rect.minY), "w": Int(rect.width), "h": Int(rect.height),
      ])
    }
    return out
  }

  /// The app the user is working in: the frontmost one, or, when Minerva itself is in front, the
  /// owner of the topmost window of another regular app.
  private func targetPid() -> pid_t? {
    if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != Self.ownPid {
      return front.processIdentifier
    }
    return (windows().first?["pid"] as? Int).map { pid_t($0) }
  }

  private func appName(_ pid: pid_t) -> String {
    NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
  }

  // MARK: - Screenshot

  func screenshot(windowId: UInt32?, done: @escaping (Any?) -> Void) {
    guard CGPreflightScreenCaptureAccess() else {
      let e = ComputerError.noScreen
      done(FlutterError(code: e.code, message: e.message, details: nil))
      return
    }
    guard #available(macOS 14.0, *) else {
      done(FlutterError(code: "unsupported", message: "Screenshots need macOS 14 or later", details: nil))
      return
    }
    Task {
      do {
        done(try await Self.capture(windowId: windowId))
      } catch let e as ComputerError {
        done(FlutterError(code: e.code, message: e.message, details: nil))
      } catch {
        done(FlutterError(code: "screenshot", message: "\(error.localizedDescription)", details: nil))
      }
    }
  }

  /// Longest side of the returned image, in pixels.
  static let maxImageSide: CGFloat = 1280

  @available(macOS 14.0, *)
  static func capture(windowId: UInt32?) async throws -> [String: Any] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let filter: SCContentFilter
    let frame: CGRect
    if let windowId = windowId {
      guard let window = content.windows.first(where: { $0.windowID == windowId }) else {
        throw ComputerError(code: "not_found", message: "No on-screen window with id \(windowId)")
      }
      filter = SCContentFilter(desktopIndependentWindow: window)
      frame = window.frame
    } else {
      let mainId = CGMainDisplayID()
      guard let display = content.displays.first(where: { $0.displayID == mainId }) ?? content.displays.first else {
        throw ComputerError(code: "not_found", message: "No display to capture")
      }
      // Without Minerva's own windows (the corner orb), so the model sees only the Mac.
      let own = content.windows.filter { $0.owningApplication?.processID == ownPid }
      filter = SCContentFilter(display: display, excludingWindows: own)
      frame = CGDisplayBounds(display.displayID)
    }
    let longest = max(frame.width, frame.height)
    guard longest > 0 else { throw ComputerError(code: "not_found", message: "Empty capture area") }
    let imageLongest = min(maxImageSide, (longest * CGFloat(filter.pointPixelScale)).rounded(.down))
    let scale = longest / imageLongest  // screen points per image pixel
    let config = SCStreamConfiguration()
    config.width = max(1, Int((frame.width / scale).rounded()))
    config.height = max(1, Int((frame.height / scale).rounded()))
    config.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
      throw ComputerError(code: "screenshot", message: "PNG encoding failed")
    }
    // The image may come back at a slightly different size; derive the scale from what we got.
    let realScale = frame.width / CGFloat(image.width)
    return [
      "png": FlutterStandardTypedData(bytes: png),
      "width": image.width, "height": image.height,
      "originX": Double(frame.minX), "originY": Double(frame.minY),
      "scale": Double(realScale),
    ]
  }

  // MARK: - Accessibility tree

  private static let interactiveRoles: Set<String> = [
    "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField", "AXCheckBox", "AXRadioButton",
    "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXSlider", "AXMenuItem", "AXDisclosureTriangle",
    "AXIncrementor", "AXColorWell", "AXTab", "AXSwitch", "AXSegmentedControl", "AXDateField",
  ]
  /// Roles worth pressing with AXPress instead of a synthetic click.
  private static let pressableRoles: Set<String> = [
    "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXPopUpButton", "AXMenuButton",
    "AXDisclosureTriangle", "AXTab", "AXSwitch",
  ]
  /// Subtrees that are noise for the model.
  private static let skippedRoles: Set<String> = ["AXScrollBar", "AXGrowArea", "AXValueIndicator", "AXSplitter"]
  private static let valueRoles: Set<String> = [
    "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXCheckBox", "AXRadioButton", "AXSlider",
    "AXPopUpButton", "AXIncrementor", "AXSwitch", "AXDateField", "AXStaticText",
  ]

  private struct Node {
    var role = ""
    var title = ""
    var desc = ""
    var value = ""
    var placeholder = ""
    var frame = CGRect.null
    var enabled = true
    var children: [AXUIElement] = []
  }

  private static let nodeAttributes = [
    kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
    kAXPlaceholderValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute,
    kAXChildrenAttribute,
  ] as CFArray

  private func read(_ el: AXUIElement, children: Bool = true) -> Node {
    var n = Node()
    var raw: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(el, Self.nodeAttributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
      == .success, let values = raw as? [AnyObject], values.count == 9
    else { return n }
    n.role = Self.string(values[0])
    n.title = Self.string(values[1])
    n.desc = Self.string(values[2])
    n.value = Self.string(values[3])
    n.placeholder = Self.string(values[4])
    if let p = Self.point(values[5]), let s = Self.size(values[6]) {
      n.frame = CGRect(origin: p, size: s)
    }
    if let e = values[7] as? NSNumber, CFGetTypeID(e) == CFBooleanGetTypeID() { n.enabled = e.boolValue }
    if children, CFGetTypeID(values[8]) == CFArrayGetTypeID() {
      // Force-cast: the array holds AXUIElements (a CF type, so `as?` cannot check it).
      n.children = (values[8] as! [AnyObject]).filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
        .map { $0 as! AXUIElement }
    }
    return n
  }

  private static func string(_ v: AnyObject?) -> String {
    guard let v = v else { return "" }
    if CFGetTypeID(v) == AXValueGetTypeID() { return "" }  // errors and geometry
    if let s = v as? String { return s }
    if let a = v as? NSAttributedString { return a.string }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
  }

  private static func point(_ v: AnyObject?) -> CGPoint? {
    guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var out = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &out) ? out : nil
  }

  private static func size(_ v: AnyObject?) -> CGSize? {
    guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var out = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &out) ? out : nil
  }

  private static func clip(_ s: String, _ n: Int = 60) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return flat.count > n ? String(flat.prefix(n - 1)) + "…" : flat
  }

  private static func label(_ n: Node) -> String {
    for s in [n.title, n.desc, n.role == "AXStaticText" ? n.value : "", n.placeholder] {
      let c = clip(s)
      if !c.isEmpty { return c }
    }
    return ""
  }

  /// One line: `AXButton "Send" = "value" (x,y w×h)`, without index or indentation.
  private static func describe(_ n: Node) -> String {
    var line = n.role.isEmpty ? "AXUnknown" : n.role
    let l = label(n)
    if !l.isEmpty { line += " \"\(l)\"" }
    if valueRoles.contains(n.role), n.role != "AXStaticText" {
      let v = clip(n.value)
      if !v.isEmpty, v != l { line += " = \"\(v)\"" }
    }
    if !n.enabled { line += " disabled" }
    if !n.frame.isNull {
      line += " (\(Int(n.frame.minX)),\(Int(n.frame.minY)) \(Int(n.frame.width))×\(Int(n.frame.height)))"
    }
    return line
  }

  func tree(pid: pid_t?, maxNodes: Int) throws -> [String: Any] {
    try requireAccessibility()
    guard let pid = pid ?? targetPid() else { throw ComputerError(code: "not_found", message: "No app in front") }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 2)
    // Chromium and Electron only build their web accessibility tree when asked to.
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

    var root: AXUIElement?
    for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
      var v: CFTypeRef?
      if AXUIElementCopyAttributeValue(app, attr as CFString, &v) == .success, let v = v,
        CFGetTypeID(v) == AXUIElementGetTypeID()
      {
        root = (v as! AXUIElement)
        break
      }
    }
    if root == nil {
      var v: CFTypeRef?
      if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
        let list = v as? [AnyObject], let first = list.first
      {
        root = (first as! AXUIElement)
      }
    }
    let name = appName(pid)
    guard let window = root else {
      cache = [:]
      return ["text": "\(name): no window", "count": 0, "app": name, "pid": Int(pid)]
    }

    let top = read(window)
    let bounds = top.frame
    var lines = ["\(name) window \"\(Self.clip(top.title))\"\(top.frame.isNull ? "" : " (\(Int(bounds.minX)),\(Int(bounds.minY)) \(Int(bounds.width))×\(Int(bounds.height)))")"]
    var elements: [Int: AXUIElement] = [:]
    var count = 0
    var visited = 0
    let maxVisited = max(maxNodes * 20, 2000)
    var truncated = false

    /// [parentText] is the full title/description of the nearest printed ancestor: static texts it
    /// already contains (button captions, row summaries) are not printed again.
    func walk(_ el: AXUIElement, _ node: Node, depth: Int, parentText: String) {
      for child in node.children {
        if count >= maxNodes || visited >= maxVisited {
          truncated = true
          return
        }
        visited += 1
        let n = read(child)
        if Self.skippedRoles.contains(n.role) { continue }
        // Off-window (scrolled away) or collapsed: skip the whole subtree.
        if !n.frame.isNull, !bounds.isNull {
          if n.frame.width <= 0 || n.frame.height <= 0 {
            if n.children.isEmpty { continue }
          } else if !n.frame.intersects(bounds) {
            continue
          }
        }
        let l = Self.label(n)
        let text = n.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicate = n.role == "AXStaticText" && !parentText.isEmpty
          && (text.isEmpty ? l.isEmpty || parentText.contains(l) : parentText.contains(text))
        let show = !duplicate && !(n.role == "AXImage" && l.isEmpty)
          && (!l.isEmpty || Self.interactiveRoles.contains(n.role) || !Self.clip(n.value).isEmpty && Self.valueRoles.contains(n.role))
        if show {
          count += 1
          elements[count] = child
          lines.append(String(repeating: "  ", count: depth) + "[\(count)] " + Self.describe(n))
          walk(child, n, depth: depth + 1, parentText: n.title + " " + n.desc)
        } else {
          walk(child, n, depth: depth, parentText: parentText)
        }
      }
    }
    walk(window, top, depth: 1, parentText: top.title)
    if truncated { lines.append("… (truncated at \(count) elements)") }
    cache = elements
    return ["text": lines.joined(separator: "\n"), "count": count, "app": name, "pid": Int(pid)]
  }

  func elementAt(_ p: CGPoint) throws -> [String: Any]? {
    try requireAccessibility()
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success,
      let el = el
    else { return nil }
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    return ["line": Self.describe(read(el, children: false)), "app": appName(pid), "pid": Int(pid)]
  }

  private func cached(_ index: Int) throws -> AXUIElement {
    guard let el = cache[index] else {
      throw ComputerError(code: "bad_index", message: "Unknown element [\(index)]: call ui_tree again")
    }
    return el
  }

  private func center(_ el: AXUIElement) throws -> CGPoint {
    let n = read(el, children: false)
    guard !n.frame.isNull, n.frame.width > 0, n.frame.height > 0 else {
      throw ComputerError(code: "gone", message: "The element is no longer on screen: call ui_tree again")
    }
    return CGPoint(x: n.frame.midX, y: n.frame.midY)
  }

  // MARK: - Mouse

  func click(index: Int, button: CGMouseButton, count: Int) throws -> String {
    try requireAccessibility()
    let el = try cached(index)
    let n = read(el, children: false)
    if button == .left, count == 1, Self.pressableRoles.contains(n.role),
      AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    {
      return "pressed [\(index)] \(Self.describe(n))"
    }
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    bringToFront(pid)
    let p = try center(el)
    try postClick(at: p, button: button, count: count)
    return "clicked [\(index)] at (\(Int(p.x)),\(Int(p.y)))"
  }

  func click(at p: CGPoint, button: CGMouseButton, count: Int) throws -> String {
    try requireAccessibility()
    // A click on a background window often only activates it; bring its app to front first.
    if let hit = try? elementAt(p), let pid = (hit["pid"] as? Int).map({ pid_t($0) }) { bringToFront(pid) }
    try postClick(at: p, button: button, count: count)
    return "clicked at (\(Int(p.x)),\(Int(p.y)))"
  }

  private func postClick(at p: CGPoint, button: CGMouseButton, count: Int) throws {
    let src = CGEventSource(stateID: .combinedSessionState)
    let (down, up): (CGEventType, CGEventType) =
      button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: button)?
      .post(tap: .cghidEventTap)
    usleep(30_000)
    for i in 1...count {
      for type in [down, up] {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else {
          throw ComputerError(code: "event", message: "Could not create a mouse event")
        }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(i))
        e.post(tap: .cghidEventTap)
        usleep(15_000)
      }
    }
  }

  func scroll(dx: Int, dy: Int, at p: CGPoint?) throws -> String {
    try requireAccessibility()
    let src = CGEventSource(stateID: .combinedSessionState)
    if let p = p {
      CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
      usleep(30_000)
    }
    // dy > 0 scrolls down (content moves up), dx > 0 scrolls right. Send it in small steps so apps
    // that ignore large deltas still move.
    let steps = max(abs(dx), abs(dy), 1)
    let sx = dx == 0 ? 0 : -dx.signum(), sy = dy == 0 ? 0 : -dy.signum()
    for i in 0..<steps {
      let wy = Int32(i < abs(dy) ? sy : 0), wx = Int32(i < abs(dx) ? sx : 0)
      guard let e = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: wy, wheel2: wx, wheel3: 0)
      else { throw ComputerError(code: "event", message: "Could not create a scroll event") }
      e.post(tap: .cghidEventTap)
      usleep(8_000)
    }
    return "scrolled dx=\(dx) dy=\(dy)" + (p.map { " at (\(Int($0.x)),\(Int($0.y)))" } ?? "")
  }

  // MARK: - Keyboard

  func type(_ text: String, index: Int?) throws -> String {
    try requireAccessibility()
    var prefix = ""
    if let index = index {
      let el = try cached(index)
      var pid: pid_t = 0
      AXUIElementGetPid(el, &pid)
      bringToFront(pid)
      let ok = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
      var focused: CFTypeRef?
      let isFocused = AXUIElementCopyAttributeValue(el, kAXFocusedAttribute as CFString, &focused) == .success
        && (focused as? Bool ?? false)
      if !ok || !isFocused { try postClick(at: try center(el), button: .left, count: 1) }
      usleep(100_000)
      prefix = "focused [\(index)], "
    }
    let src = CGEventSource(stateID: .combinedSessionState)
    var chunk: [UniChar] = []
    func flush() {
      guard !chunk.isEmpty else { return }
      for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
        e?.flags = []
        chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
        e?.post(tap: .cghidEventTap)
      }
      chunk.removeAll()
      usleep(8_000)
    }
    for ch in text {
      if ch == "\n" || ch == "\r\n" {
        flush()
        try postKey(CGKeyCode(kVK_Return), flags: [])
        continue
      }
      let units = Array(String(ch).utf16)
      if chunk.count + units.count > 16 { flush() }
      chunk.append(contentsOf: units)
    }
    flush()
    return prefix + "typed \(text.count) characters"
  }

  func key(_ combo: String) throws -> String {
    try requireAccessibility()
    var flags: CGEventFlags = []
    var code: CGKeyCode?
    // "cmd++" means cmd and the plus key.
    var parts = combo.lowercased().split(separator: "+", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    if parts.count > 1, parts.last == "", parts[parts.count - 2] == "" { parts.removeLast(2); parts.append("+") }
    for p in parts where !p.isEmpty {
      switch p {
      case "cmd", "command", "⌘", "meta", "super": flags.insert(.maskCommand)
      case "shift", "⇧": flags.insert(.maskShift)
      case "alt", "option", "opt", "⌥": flags.insert(.maskAlternate)
      case "ctrl", "control", "⌃": flags.insert(.maskControl)
      case "fn": flags.insert(.maskSecondaryFn)
      default:
        guard code == nil, let c = Self.keyCode(p) else {
          throw ComputerError.badArgs("Unknown key \"\(p)\" in \"\(combo)\"")
        }
        code = c
      }
    }
    guard let code = code else { throw ComputerError.badArgs("No key in \"\(combo)\"") }
    try postKey(code, flags: flags)
    return "pressed \(combo)"
  }

  private func postKey(_ code: CGKeyCode, flags: CGEventFlags) throws {
    let src = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
      guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else {
        throw ComputerError(code: "event", message: "Could not create a key event")
      }
      e.flags = flags
      e.post(tap: .cghidEventTap)
      usleep(10_000)
    }
  }

  private static let namedKeys: [String: Int] = [
    "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
    "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete, "del": kVK_ForwardDelete,
    "escape": kVK_Escape, "esc": kVK_Escape, "left": kVK_LeftArrow, "right": kVK_RightArrow,
    "up": kVK_UpArrow, "down": kVK_DownArrow, "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp,
    "pagedown": kVK_PageDown, "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5,
    "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    "plus": kVK_ANSI_Equal, "minus": kVK_ANSI_Minus, "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period,
    "slash": kVK_ANSI_Slash,
  ]

  /// Fallback for characters when the current layout cannot produce them (US positions).
  private static let ansiKeys: [Character: Int] = [
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
    "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
    "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
    "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
    "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
    "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
    ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
    "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
  ]

  static func keyCode(_ name: String) -> CGKeyCode? {
    if let c = namedKeys[name] { return CGKeyCode(c) }
    guard name.count == 1, let ch = name.first else { return nil }
    if let c = layoutKeys()[ch] { return c }
    return ansiKeys[ch].map { CGKeyCode($0) }
  }

  /// Character -> key code for the current keyboard layout (unshifted), so "cmd+," or "cmd+z"
  /// hit the right key on non-US layouts.
  private static func layoutKeys() -> [Character: CGKeyCode] {
    // Text Input Sources must be used on the main thread.
    let build = { () -> [Character: CGKeyCode] in
      guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
        let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
      else { return [:] }
      let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
      var map: [Character: CGKeyCode] = [:]
      data.withUnsafeBytes { raw in
        guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
        for code in 0..<128 {
          var dead: UInt32 = 0
          var chars = [UniChar](repeating: 0, count: 4)
          var len = 0
          let status = UCKeyTranslate(
            layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars)
          guard status == noErr, len == 1, let ch = String(utf16CodeUnits: chars, count: len).lowercased().first
          else { continue }
          if map[ch] == nil { map[ch] = CGKeyCode(code) }
        }
      }
      return map
    }
    return Thread.isMainThread ? build() : DispatchQueue.main.sync(execute: build)
  }

  // MARK: - Apps

  func open(_ target: String) throws -> String {
    let ws = NSWorkspace.shared
    let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: t), let scheme = url.scheme, scheme.count > 1, !t.hasPrefix("/") {
      guard ws.open(url) else { throw ComputerError(code: "open", message: "Nothing could open \(t)") }
      return "opened \(t)"
    }
    if t.hasPrefix("/") || t.hasPrefix("~") {
      let path = (t as NSString).expandingTildeInPath
      guard FileManager.default.fileExists(atPath: path) else {
        throw ComputerError(code: "not_found", message: "No such file: \(path)")
      }
      if path.hasSuffix(".app") { return try launch(URL(fileURLWithPath: path)) }
      guard ws.open(URL(fileURLWithPath: path)) else { throw ComputerError(code: "open", message: "Could not open \(path)") }
      return "opened \(path)"
    }
    if let url = ws.urlForApplication(withBundleIdentifier: t) { return try launch(url) }
    if let url = Self.findApp(named: t) { return try launch(url) }
    // A bare domain such as "elpais.com".
    if !t.contains(" "), t.contains("."), let url = URL(string: "https://" + t), url.host != nil {
      guard ws.open(url) else { throw ComputerError(code: "open", message: "Nothing could open \(t)") }
      return "opened https://\(t)"
    }
    throw ComputerError(code: "not_found", message: "No app, URL or file matches \"\(t)\"")
  }

  private static func findApp(named name: String) -> URL? {
    let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let dirs = [
      "/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
      "\(home)/Applications", "/System/Library/CoreServices/Applications",
    ]
    for dir in dirs {
      guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
      if let hit = items.first(where: { $0.lowercased() == wanted + ".app" }) {
        return URL(fileURLWithPath: dir).appendingPathComponent(hit)
      }
    }
    // A running app by its localized name (e.g. "Calendario").
    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.lowercased() == wanted }) {
      return app.bundleURL
    }
    return nil
  }

  private func launch(_ url: URL) throws -> String {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    let done = DispatchSemaphore(value: 0)
    var failure: Error?
    var name = url.deletingPathExtension().lastPathComponent
    NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
      failure = error
      if let n = app?.localizedName { name = n }
      done.signal()
    }
    if done.wait(timeout: .now() + 15) == .timedOut { return "launching \(name)" }
    if let e = failure { throw ComputerError(code: "open", message: "Could not open \(name): \(e.localizedDescription)") }
    return "opened \(name)"
  }

  func activate(_ pid: pid_t) throws -> String {
    guard NSRunningApplication(processIdentifier: pid) != nil else {
      throw ComputerError(code: "not_found", message: "No running app with pid \(pid)")
    }
    bringToFront(pid)
    return "activated \(appName(pid))"
  }

  /// Makes [pid] the frontmost app (no-op when it already is, or when it is Minerva itself).
  private func bringToFront(_ pid: pid_t) {
    guard pid > 0, pid != Self.ownPid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
      let app = NSRunningApplication(processIdentifier: pid)
    else { return }
    app.activate(options: [.activateAllWindows])
    // Cooperative activation may refuse the request; AX frontmost is honoured with Accessibility.
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    usleep(200_000)
  }
}

struct ComputerError: Error {
  let code: String
  let message: String

  static let noAccessibility = ComputerError(
    code: "no_accessibility",
    message: "Accessibility permission missing: enable Minerva in System Settings > Privacy & Security > Accessibility")
  static let noScreen = ComputerError(
    code: "no_screen",
    message: "Screen Recording permission missing: enable Minerva in System Settings > Privacy & Security > "
      + "Screen & System Audio Recording, then restart Minerva")

  static func badArgs(_ message: String) -> ComputerError { ComputerError(code: "bad_args", message: message) }
}
