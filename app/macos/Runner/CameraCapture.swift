import AVFoundation
import FlutterMacOS
import ImageIO
import UniformTypeIdentifiers

/// Photos from the Mac's camera for the brain's `camera` tool (lib/camera/camera_tools.dart).
///
/// Method channel `minerva/camera`:
///   capture                    -> {jpeg, camera}       one photo from the built-in camera
///                                                      (else the system's preferred one)
///   prepare {data, maxSide}    -> {full, small, width, height}
///                                 any image (a photo from the phone too) upright as its EXIF
///                                 orientation says: full size and at most maxSide px a side,
///                                 both JPEG
///
/// Errors: `no_camera` (access denied), `no_device`, `bad_image`, `failed`.
final class CameraCapture: NSObject {
  private let channel: FlutterMethodChannel
  private var session: AVCaptureSession?
  private var delegate: PhotoDelegate?
  /// The session runs this long before the photo, so exposure and white balance settle.
  private static let warmUp: TimeInterval = 1.2

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "minerva/camera", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "capture":
      capture(result)
    case "prepare":
      guard let data = (args["data"] as? FlutterStandardTypedData)?.data else {
        result(FlutterError(code: "bad_args", message: "data is required", details: nil))
        return
      }
      let maxSide = (args["maxSide"] as? NSNumber)?.intValue ?? 1568
      DispatchQueue.global(qos: .userInitiated).async {
        let reply = CameraCapture.prepare(data, maxSide: maxSide)
        DispatchQueue.main.async { result(reply) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Capture

  private func capture(_ result: @escaping FlutterResult) {
    guard session == nil else {
      result(FlutterError(code: "failed", message: "the camera is already taking a photo", details: nil))
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      start(result)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          if granted {
            self.start(result)
          } else {
            result(CameraCapture.denied)
          }
        }
      }
    default:
      result(CameraCapture.denied)
    }
  }

  private static let denied = FlutterError(
    code: "no_camera",
    message: "Minerva has no access to the camera (System Settings > Privacy & Security > Camera)",
    details: nil)

  /// The built-in camera when there is one: the system's preferred camera can be an iPhone
  /// (Continuity Camera) that is not where the user is.
  private static func device() -> AVCaptureDevice? {
    var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
    if #available(macOS 14.0, *) {
      types += [.external, .continuityCamera]
    } else {
      types.append(.externalUnknown)
    }
    let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
      .devices
    if let builtIn = found.first(where: { $0.deviceType == .builtInWideAngleCamera }) { return builtIn }
    if #available(macOS 13.0, *), let preferred = AVCaptureDevice.systemPreferredCamera { return preferred }
    return found.first ?? AVCaptureDevice.default(for: .video)
  }

  private func start(_ result: @escaping FlutterResult) {
    guard let device = CameraCapture.device() else {
      result(FlutterError(code: "no_device", message: "this Mac has no camera", details: nil))
      return
    }
    let session = AVCaptureSession()
    session.sessionPreset = .photo
    let output = AVCapturePhotoOutput()
    do {
      let input = try AVCaptureDeviceInput(device: device)
      guard session.canAddInput(input), session.canAddOutput(output) else {
        throw NSError(domain: "minerva.camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot use \(device.localizedName)"])
      }
      session.addInput(input)
      session.addOutput(output)
    } catch {
      result(FlutterError(code: "failed", message: "\(error.localizedDescription)", details: nil))
      return
    }
    self.session = session
    let name = device.localizedName
    let finish: (Any?) -> Void = { [weak self] value in
      DispatchQueue.main.async {
        self?.session?.stopRunning()
        self?.session = nil
        self?.delegate = nil
        result(value)
      }
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      session.startRunning()
      DispatchQueue.main.asyncAfter(deadline: .now() + CameraCapture.warmUp) {
        guard let self = self, session.isRunning else {
          finish(FlutterError(code: "failed", message: "the camera did not start", details: nil))
          return
        }
        let settings = output.availablePhotoCodecTypes.contains(.jpeg)
          ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
          : AVCapturePhotoSettings()
        let delegate = PhotoDelegate { data, error in
          if let data = data {
            finish(["jpeg": FlutterStandardTypedData(bytes: data), "camera": name])
          } else {
            finish(FlutterError(code: "failed", message: error ?? "no photo", details: nil))
          }
        }
        self.delegate = delegate
        output.capturePhoto(with: settings, delegate: delegate)
      }
    }
  }

  // MARK: - Prepare

  /// [data] upright (EXIF orientation applied) as JPEG, full size and scaled to [maxSide].
  static func prepare(_ data: Data, maxSide: Int) -> Any {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    else {
      return FlutterError(code: "bad_image", message: "not an image", details: nil)
    }
    let longest = max(w, h)
    func upright(_ side: Int) -> CGImage? {
      CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: side,
      ] as CFDictionary)
    }
    guard let full = upright(longest), let small = longest > maxSide ? upright(maxSide) : full,
          let fullJpeg = jpeg(full, quality: 0.9), let smallJpeg = jpeg(small, quality: 0.8)
    else {
      return FlutterError(code: "bad_image", message: "could not decode the image", details: nil)
    }
    return [
      "full": FlutterStandardTypedData(bytes: fullJpeg),
      "small": FlutterStandardTypedData(bytes: smallJpeg),
      "width": full.width,
      "height": full.height,
    ]
  }

  private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(dest) ? out as Data : nil
  }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  init(_ done: @escaping (Data?, String?) -> Void) {
    self.done = done
  }

  private let done: (Data?, String?) -> Void

  func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    if let error = error {
      done(nil, error.localizedDescription)
    } else {
      done(photo.fileDataRepresentation(), nil)
    }
  }
}
