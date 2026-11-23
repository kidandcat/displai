import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var audio: VoiceAudio?
  private var computer: ComputerControl?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    audio = VoiceAudio(messenger: flutterViewController.engine.binaryMessenger)
    computer = ComputerControl(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
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
}
