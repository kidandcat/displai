// Full-duplex audio helper with macOS voice processing (echo cancellation).
//
// Capture and playback must go through the same voice-processing I/O unit so the
// canceller knows what the speakers are playing. This helper owns both:
//
//   stdout: echo-cancelled mic audio, 16 kHz mono float32 little-endian, raw stream.
//   stdin:  frames of [UInt32 kind][UInt32 count] + payload (little-endian):
//             kind 1 = play `count` float32 samples at the playback rate (argv[1], default 44100)
//             kind 2 = stop playback now and drop everything queued (count = 0)
//   stderr: one event per line: "EV ready", "EV idle" (playback queue drained), "EV error ...".
//
// Usage: audioio [playback_sample_rate]

import AVFoundation
import Foundation

func emit(_ s: String) {
    FileHandle.standardError.write(("EV " + s + "\n").data(using: .utf8)!)
}

let playRate = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "44100") ?? 44100
let engine = AVAudioEngine()
let input = engine.inputNode
// Touch the output graph before enabling voice processing; otherwise the VPIO
// output unit can fail to initialize (-10875) on some Macs.
_ = engine.outputNode
_ = engine.mainMixerNode

do {
    try input.setVoiceProcessingEnabled(true)
} catch {
    emit("error voice-processing \(error)")
    exit(1)
}
if #available(macOS 14.0, *) {
    // Do not duck other audio more than necessary while voice processing is on.
    input.voiceProcessingOtherAudioDuckingConfiguration =
        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
}

// Playback path: player -> main mixer -> output (the canceller's reference signal).
let player = AVAudioPlayerNode()
engine.attach(player)
let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: playRate, channels: 1, interleaved: false)!
engine.connect(player, to: engine.mainMixerNode, format: playFormat)

// Capture path: tap the voice-processed input, keep channel 0, resample to 16 kHz.
let inFormat = input.outputFormat(forBus: 0)
let monoIn = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 1, interleaved: false)!
let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
guard let converter = AVAudioConverter(from: monoIn, to: outFormat) else {
    emit("error converter \(inFormat)")
    exit(1)
}
let writeQueue = DispatchQueue(label: "stdout")

input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buf, _ in
    let n = buf.frameLength
    guard n > 0, let src = buf.floatChannelData else { return }
    let mono = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: n)!
    mono.frameLength = n
    memcpy(mono.floatChannelData![0], src[0], Int(n) * 4)
    let cap = AVAudioFrameCount(Double(n) * 16000 / inFormat.sampleRate) + 64
    let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap)!
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
    writeQueue.async { FileHandle.standardOutput.write(data) }
}

let lock = NSLock()
var pending = 0
var generation = 0

func readExact(_ n: Int) -> Data? {
    var data = Data()
    while data.count < n {
        let chunk = FileHandle.standardInput.readData(ofLength: n - data.count)
        if chunk.isEmpty { return nil }
        data.append(chunk)
    }
    return data
}

func u32(_ d: Data, _ off: Int) -> UInt32 {
    d.subdata(in: off..<off + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
}

engine.prepare()
do {
    try engine.start()
} catch {
    emit("error start \(error)")
    exit(1)
}
player.play()
emit("ready in=\(inFormat.sampleRate)Hz/\(inFormat.channelCount)ch play=\(playRate)Hz")

Thread {
    while let header = readExact(8) {
        let kind = u32(header, 0)
        let count = Int(u32(header, 4))
        if kind == 1 {
            guard let payload = readExact(count * 4), count > 0 else { continue }
            let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(count))!
            buf.frameLength = AVAudioFrameCount(count)
            _ = payload.withUnsafeBytes { raw in
                memcpy(buf.floatChannelData![0], raw.baseAddress!, count * 4)
            }
            lock.lock()
            pending += 1
            let gen = generation
            lock.unlock()
            player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in
                lock.lock()
                if gen == generation { pending -= 1 }
                let idle = gen == generation && pending == 0
                lock.unlock()
                if idle { emit("idle") }
            }
        } else if kind == 2 {
            lock.lock()
            generation += 1
            pending = 0
            lock.unlock()
            player.stop()
            player.play()
            emit("idle")
        }
    }
    exit(0)
}.start()

dispatchMain()
