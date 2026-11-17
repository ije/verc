import MetalKit
import SwiftUI
import os

struct PrismBackground: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    PrismSurface(suspended: scenePhase != .active, reduceMotion: reduceMotion)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct PrismSurface: NSViewRepresentable {
  var suspended: Bool
  var reduceMotion: Bool

  func makeCoordinator() -> PrismRenderer? { PrismRenderer(device: PrismResources.device) }

  func makeNSView(context: Context) -> PrismMetalView {
    let view = PrismMetalView(frame: .zero, device: PrismResources.device)
    view.colorPixelFormat = .bgra8Unorm
    view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    view.autoResizeDrawable = false
    view.delegate = context.coordinator
    context.coordinator?.view = view
    return view
  }

  func updateNSView(_ view: PrismMetalView, context: Context) {
    context.coordinator?.reduceMotion = reduceMotion
    view.suspended = suspended
    view.schedule()
  }

  static func dismantleNSView(_ view: PrismMetalView, coordinator: PrismRenderer?) {
    view.teardown()
    view.isPaused = true
    view.delegate = nil
  }
}

private final class PrismMetalView: MTKView {
  private var tracking: NSTrackingArea?
  private var pointerMonitor: Any?
  private var observers: [NSObjectProtocol] = []
  var suspended = false

  private var renderer: PrismRenderer? { delegate as? PrismRenderer }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    resizeDrawable()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    resizeDrawable()
  }

  private func resizeDrawable() {
    let scale = min(window?.backingScaleFactor ?? 2, 2560 / max(bounds.width, bounds.height, 1))
    let size = CGSize(
      width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
    if drawableSize != size { drawableSize = size }
    schedule()
  }

  func schedule() {
    let visible = window?.occlusionState.contains(.visible) ?? false
    let running = renderer?.animating == true && visible && !suspended && NSApp.isActive
    if running, let renderer {
      let rate = renderer.interactive ? 60 : 30
      if preferredFramesPerSecond != rate { preferredFramesPerSecond = rate }
    }
    if isPaused == running { isPaused = !running }
    if enableSetNeedsDisplay == running { enableSetNeedsDisplay = !running }
    if !running, renderer?.needsFrame == true { needsDisplay = true }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    teardown()
    guard let window else { return }
    window.acceptsMouseMovedEvents = true
    pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .mouseMoved, .leftMouseDragged, .leftMouseDown,
    ]) { [weak self] event in
      if let self, event.window === self.window {
        if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
          self.mouseMoved(with: event)
        } else {
          self.mouseExited(with: event)
        }
      }
      return event
    }
    observers = [
      (NSWindow.didChangeOcclusionStateNotification, window),
      (NSApplication.didBecomeActiveNotification, nil),
      (NSApplication.didResignActiveNotification, nil),
    ].map { name, object in
      NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.schedule() }
      }
    }
    resizeDrawable()
  }

  func teardown() {
    if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    pointerMonitor = nil
    observers = []
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    renderer?.point(at: SIMD2(point.x / max(bounds.width, 1), 1 - point.y / max(bounds.height, 1)))
    schedule()
  }

  override func mouseExited(with event: NSEvent) {
    renderer?.leave()
    schedule()
  }
}

// Shared buffers and textures must stay immutable after initialization.
private final class PrismResources: @unchecked Sendable {
  static let device = MTLCreateSystemDefaultDevice()
  static let shared = Task.detached(priority: .userInitiated) { try PrismResources(bundle: .main) }

  enum Blend { case replace, additive, premultiplied }

  let queue: any MTLCommandQueue
  let light, glassBack, glassFront, copy, extract, packedBlur, wideBlur, particle, composite,
    present, antialias, reveal, dust: any MTLRenderPipelineState
  let glassVertices, glassIndices, spectrum: any MTLBuffer
  let glassIndexCount: Int
  let environment: any MTLTexture

  init(bundle: Bundle) throws {
    guard let device = Self.device, let queue = device.makeCommandQueue() else {
      throw CocoaError(.featureUnsupported)
    }
    self.queue = queue
    let library = try device.makeDefaultLibrary(bundle: bundle)
    func pipeline(
      _ vertex: String, _ fragment: String, _ format: MTLPixelFormat, samples: Int = 1,
      blend: Blend = .replace
    ) throws -> any MTLRenderPipelineState {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: vertex)
      descriptor.fragmentFunction = library.makeFunction(name: fragment)
      descriptor.rasterSampleCount = samples
      let color = descriptor.colorAttachments[0]!
      color.pixelFormat = format
      color.isBlendingEnabled = blend != .replace
      color.sourceRGBBlendFactor = .one
      color.sourceAlphaBlendFactor = .one
      color.destinationRGBBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
      color.destinationAlphaBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
      return try device.makeRenderPipelineState(descriptor: descriptor)
    }
    light = try pipeline("lightVertex", "lightFragment", .rgba16Float, samples: 4, blend: .additive)
    glassBack = try pipeline(
      "glassVertex", "glassBack", .rgba16Float, samples: 4, blend: .premultiplied)
    copy = try pipeline("screenVertex", "copyLinear", .rgba16Float, samples: 4)
    glassFront = try pipeline("glassVertex", "glassFront", .rgba16Float, samples: 4)
    extract = try pipeline("screenVertex", "bloomExtract", .rg11b10Float)
    packedBlur = try pipeline("screenVertex", "bloomBlur", .rg11b10Float)
    wideBlur = try pipeline("screenVertex", "bloomBlur", .rgba16Float)
    particle = try pipeline("screenVertex", "particleLight", .rgba16Float)
    composite = try pipeline("screenVertex", "bloomComposite", .rg11b10Float)
    present = try pipeline("screenVertex", "presentScene", .rgba16Float)
    antialias = try pipeline("screenVertex", "antialiasScene", .bgra8Unorm)
    reveal = try pipeline("screenVertex", "revealScene", .bgra8Unorm)
    dust = try pipeline("dustVertex", "dustFragment", .bgra8Unorm, blend: .additive)

    let glass = PrismScene.glassMesh()
    var colors = (0..<128).map { index -> SIMD4<Float> in
      let wavelength = PrismScene.wavelength(index, of: 128)
      return SIMD4(SIMD3<Float>(PrismScene.beamColor(wavelength)), Float(wavelength))
    }
    guard
      let glassVertices = device.makeBuffer(
        bytes: glass.vertices, length: glass.vertices.count * 4),
      let glassIndices = device.makeBuffer(bytes: glass.indices, length: glass.indices.count * 2),
      let spectrum = device.makeBuffer(
        bytes: &colors, length: colors.count * MemoryLayout<SIMD4<Float>>.stride),
      let command = queue.makeCommandBuffer()
    else { throw CocoaError(.featureUnsupported) }
    (self.glassVertices, self.glassIndices, glassIndexCount) = (
      glassVertices, glassIndices, glass.indices.count
    )
    self.spectrum = spectrum

    func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, levels: Int) throws
      -> any MTLTexture
    {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format, width: width, height: height, mipmapped: levels > 1)
      descriptor.mipmapLevelCount = levels
      descriptor.usage = [.renderTarget, .shaderRead, .pixelFormatView]
      descriptor.storageMode = .private
      guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw CocoaError(.featureUnsupported)
      }
      return texture
    }
    func draw(
      _ target: any MTLTexture, level: Int = 0, _ state: any MTLRenderPipelineState,
      _ body: (any MTLRenderCommandEncoder) -> Void = { _ in }
    ) {
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].level = level
      pass.colorAttachments[0].loadAction = .dontCare
      pass.colorAttachments[0].storeAction = .store
      guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
      encoder.setRenderPipelineState(state)
      body(encoder)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      encoder.endEncoding()
    }

    environment = try texture(.rgba16Float, 1024, 512, levels: 8)
    draw(environment, try pipeline("screenVertex", "bakeEnvironment", .rgba16Float))
    let blur = try pipeline("screenVertex", "blurEnvironment", .rgba16Float)
    for level in 1..<environment.mipmapLevelCount {
      let width = 1024 >> level
      let height = 512 >> level
      let horizontal = try texture(.rgba16Float, width, height, levels: 1)
      guard
        let source = environment.makeTextureView(
          pixelFormat: .rgba16Float, textureType: .type2D,
          levels: (level - 1)..<level, slices: 0..<1)
      else { throw CocoaError(.featureUnsupported) }
      for (target, input, direction) in [
        (horizontal, source, SIMD4<Float>(1 / Float(width), 0, 1.15, 1)),
        (environment, horizontal, SIMD4<Float>(0, 1 / Float(height), 1.15, 0)),
      ] {
        var parameters = direction
        draw(target, level: target === environment ? level : 0, blur) {
          $0.setFragmentTexture(input, index: 0)
          $0.setFragmentBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        }
      }
    }

    command.commit()
    command.waitUntilCompleted()
    if let error = command.error { throw error }
  }
}

@MainActor private final class PrismRenderer: NSObject, MTKViewDelegate {
  private typealias Vec = PrismScene.Vec

  // Keep this layout identical to Scene in Prism.metal.
  private struct Uniforms {
    var viewProjection = matrix_identity_float4x4
    var camera = SIMD4<Float>.zero
    var output = SIMD4<Float>.zero
    var timing = SIMD4<Float>.zero
    var glass = SIMD4<Float>.zero
    var absorption = SIMD4<Float>.zero
    var planes = (
      SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero
    )
    // Front corner UVs for dust, with the light z in the last lane.
    var prism = (SIMD4<Float>.zero, SIMD4<Float>.zero)
    var layout = SIMD4<UInt32>.zero
  }

  private struct BlurParameters {
    var direction: SIMD2<Float>
    var texel: SIMD2<Float>
    var coefficients:
      (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var taps: UInt32
  }

  private struct Targets {
    var size: SIMD2<Int>
    var backdrop: any MTLTexture
    var multisample: any MTLTexture
    var scene: any MTLTexture
    var bloom: [(horizontal: any MTLTexture, vertical: any MTLTexture)]
    var presentation: any MTLTexture
  }

  private static let layout = PrismScene.LightLayout(samples: 128, slices: 24)
  private static let bloomKernels = [6, 10, 14, 18].map { taps in
    let sigma = Double(taps) / 3
    let weights = (0..<24).map { $0 < taps ? exp(-0.5 * Double($0 * $0) / (sigma * sigma)) : 0 }
    let total = weights[0] + 2 * weights.dropFirst().reduce(0, +)
    let w = weights.map { Float($0 / total) }
    return BlurParameters(
      direction: .zero, texel: .zero,
      coefficients: (
        SIMD4(w[0...3]), SIMD4(w[4...7]), SIMD4(w[8...11]), SIMD4(w[12...15]),
        SIMD4(w[16...19]), SIMD4(w[20...23])
      ),
      taps: UInt32(taps))
  }
  private static let bloomDivisors = [2, 4, 8, 16]
  private static let dustCount = 2200

  let device: any MTLDevice
  weak var view: PrismMetalView?
  private var resources: PrismResources?
  private let lightBuffers: [any MTLBuffer]
  private let inFlight = DispatchSemaphore(value: 3)
  private var lightIndex = 0
  private var targets: Targets?
  private var uniforms = Uniforms()
  private static let restingAim = Vec(0.022, 0.45)
  private var aim = restingAim, aimTarget = restingAim
  private var orbit = Vec.zero, orbitTarget = Vec.zero
  private var builtLight: (aim: Vec, wall: Vec)?
  private var started: CFTimeInterval?
  private var sceneDirty = true
  private var presentedBeam: Float?
  var reduceMotion = false {
    didSet {
      guard reduceMotion != oldValue else { return }
      (aim, aimTarget, orbit, orbitTarget) = (Self.restingAim, Self.restingAim, .zero, .zero)
      invalidate()
    }
  }

  init?(device: (any MTLDevice)?) {
    guard let device else { return nil }
    let length = Self.layout.vertexCount * 3 * MemoryLayout<Float>.stride
    let buffers = (0..<3).compactMap { _ in
      device.makeBuffer(length: length, options: .storageModeShared)
    }
    guard buffers.count == 3 else { return nil }
    self.device = device
    lightBuffers = buffers
    super.init()
    let planes = PrismScene.planes
    uniforms.planes = (planes[0], planes[1], planes[2], planes[3], planes[4])
    uniforms.prism.1.w = Float(PrismScene.lightZ)
    uniforms.layout = SIMD4(
      UInt32(Self.layout.whiteQuads), UInt32(Self.layout.slices), UInt32(Self.layout.samples),
      UInt32(Self.layout.internalQuads))
    let ior = PrismScene.ior
    uniforms.glass = SIMD4(Float(ior), Float(pow((ior - 1) / (ior + 1), 2)), 2.14, 2.3)
    uniforms.absorption = SIMD4(1, 1, 0.54, 0)
    Task { [weak self] in
      do {
        let resources = try await PrismResources.shared.value
        self?.resources = resources
        self?.view?.schedule()
      } catch {
        Logger(subsystem: "me.jex.verc", category: "Prism").error(
          "Unable to render prism: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  var animating: Bool { resources != nil && (interactive || !reduceMotion) }
  var interactive: Bool {
    sceneDirty || aim != aimTarget || orbit != orbitTarget || revealProgress().beam < 1
  }
  var needsFrame: Bool { resources != nil && (sceneDirty || presentedBeam == nil) }

  func point(at position: SIMD2<Double>) {
    guard !reduceMotion else { return }
    let x = min(1, max(0, position.x))
    let y = min(1, max(0, position.y))
    aimTarget = Vec(y, x)
    orbitTarget = Vec(x * 2 - 1, y * 2 - 1)
  }

  func leave() { orbitTarget = .zero }

  func invalidate() { sceneDirty = true }

  private func ease(_ current: inout Vec, _ target: Vec, _ amount: Double, snap: Double) -> Bool {
    if current == target { return false }
    let delta = target - current
    current = abs(delta.x) < snap && abs(delta.y) < snap ? target : current + delta * amount
    return true
  }

  private func revealProgress(at now: CFTimeInterval = CACurrentMediaTime()) -> (
    opacity: Float, beam: Float
  ) {
    guard !reduceMotion, let started else { return (1, 1) }
    let elapsed = Float(now - started)
    let beamStart: Float = 1 - cbrt(0.75)
    return (
      1 - pow(1 - min(1, max(0, elapsed)), 3),
      1 - pow(1 - min(1, max(0, (elapsed - beamStart) / (2.5 - beamStart))), 3)
    )
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { invalidate() }

  func draw(in view: MTKView) {
    guard let resources else { return }
    let size = SIMD2(Int(view.drawableSize.width), Int(view.drawableSize.height))
    if targets?.size != size {
      targets = makeTargets(size)
      sceneDirty = true
    }
    // Pause until the next schedule() instead of presenting blank frames.
    guard let targets else {
      view.isPaused = true
      return
    }
    // Wait before taking a drawable, so a blocked frame does not hold one of the few drawables.
    inFlight.wait()
    guard let drawable = view.currentDrawable, let command = resources.queue.makeCommandBuffer()
    else {
      inFlight.signal()
      return
    }
    command.addCompletedHandler { [inFlight] _ in inFlight.signal() }
    encode(command, resources, targets, output: drawable.texture, now: CACurrentMediaTime())
    command.present(drawable)
    command.commit()
    (view as? PrismMetalView)?.schedule()
  }

  private func encode(
    _ command: any MTLCommandBuffer, _ resources: PrismResources, _ targets: Targets,
    output: any MTLTexture, now: CFTimeInterval
  ) {
    if started == nil { started = now }
    let aimed = ease(&aim, aimTarget, 0.12, snap: 1e-4)
    // Orbit steps below 3e-3 move the image less than a pixel, so stop there instead of rendering identical frames.
    let orbited = ease(&orbit, orbitTarget, 0.08, snap: 3e-3)
    let progress = revealProgress(at: now)
    // Prism.metal makes dust motion repeat every 3600 seconds, so this wrap is seamless.
    let dustTime =
      reduceMotion
      ? 0 : Float((floor((now - started!) * 30) / 30).truncatingRemainder(dividingBy: 3600))
    uniforms.timing = SIMD4(dustTime, progress.opacity, progress.beam, 0)
    if sceneDirty || aimed || orbited || presentedBeam != progress.beam {
      update(targets.size)
      encodeScene(command, resources, targets)
      sceneDirty = false
      presentedBeam = progress.beam
    }
    pass(command, output, load: .dontCare) { encoder in
      fullscreen(encoder, resources.reveal, [targets.presentation])
      encoder.setRenderPipelineState(resources.dust)
      encoder.setFragmentTexture(targets.bloom[1].vertical, index: 0)
      encoder.setFragmentTexture(targets.bloom[3].vertical, index: 1)
      encoder.drawPrimitives(
        type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: Self.dustCount)
    }
  }

  private func update(_ size: SIMD2<Int>) {
    let aspect = Double(size.x) / Double(max(size.y, 1))
    let camera = PrismScene.camera(aspect: aspect, orbit: orbit)
    uniforms.viewProjection = camera.viewProjection
    uniforms.camera = SIMD4(camera.position, Float(PrismScene.cameraDistance))
    uniforms.output = SIMD4(
      Float(size.x), Float(size.y), Float(camera.wall.x), Float(camera.wall.y))
    let uv = PrismScene.triangle.map { corner -> SIMD2<Float> in
      let clip =
        camera.viewProjection
        * SIMD4(lowHalf: SIMD2<Float>(corner), highHalf: SIMD2(Float(PrismScene.frontZ), 1))
      return SIMD2(clip.x, -clip.y) / max(clip.w, 1e-5) * 0.5 + 0.5
    }
    uniforms.prism = (
      SIMD4(lowHalf: uv[0], highHalf: uv[1]),
      SIMD4(lowHalf: uv[2], highHalf: SIMD2(0, uniforms.prism.1.w))
    )
    let wall = camera.wall * min(2.5, max(1, 1 / aspect))
    if builtLight?.aim != aim || builtLight?.wall != wall {
      let lamp = PrismScene.Lamp(arc: aim.x, target: aim.y)
      lightIndex = (lightIndex + 1) % lightBuffers.count
      PrismScene.buildLight(
        Self.layout, lamp: lamp, wall: wall,
        into: lightBuffers[lightIndex].contents().bindMemory(
          to: Float.self, capacity: Self.layout.vertexCount * 3))
      builtLight = (aim, wall)
    }
  }

  private func makeTargets(_ size: SIMD2<Int>) -> Targets? {
    func texture(
      _ format: MTLPixelFormat, _ width: Int, _ height: Int, samples: Int = 1,
      mipmapped: Bool = false
    ) -> (any MTLTexture)? {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: mipmapped)
      if samples > 1 {
        descriptor.textureType = .type2DMultisample
        descriptor.sampleCount = samples
        descriptor.usage = .renderTarget
        descriptor.storageMode = .memoryless
      } else {
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
      }
      return device.makeTexture(descriptor: descriptor)
    }
    let bloom = Self.bloomDivisors.enumerated().compactMap {
      level, divisor -> (horizontal: any MTLTexture, vertical: any MTLTexture)? in
      let format: MTLPixelFormat = level < 3 ? .rg11b10Float : .rgba16Float
      let width = (size.x + divisor - 1) / divisor
      let height = (size.y + divisor - 1) / divisor
      guard let horizontal = texture(format, width, height),
        let vertical = texture(format, width, height)
      else { return nil }
      return (horizontal, vertical)
    }
    guard bloom.count == Self.bloomDivisors.count,
      let backdrop = texture(.rgba16Float, size.x, size.y, mipmapped: true),
      let multisample = texture(.rgba16Float, size.x, size.y, samples: 4),
      let scene = texture(.rgba16Float, size.x, size.y),
      let presentation = texture(.bgra8Unorm, size.x, size.y)
    else { return nil }
    return Targets(
      size: size, backdrop: backdrop, multisample: multisample, scene: scene, bloom: bloom,
      presentation: presentation)
  }

  private func pass(
    _ command: any MTLCommandBuffer, _ target: any MTLTexture, resolve: (any MTLTexture)? = nil,
    load: MTLLoadAction = .clear, _ body: (any MTLRenderCommandEncoder) -> Void
  ) {
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = target
    descriptor.colorAttachments[0].resolveTexture = resolve
    descriptor.colorAttachments[0].loadAction = load
    descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    descriptor.colorAttachments[0].storeAction = resolve == nil ? .store : .multisampleResolve
    guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
    encoder.setFrontFacing(.counterClockwise)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    body(encoder)
    encoder.endEncoding()
  }

  private func fullscreen(
    _ encoder: any MTLRenderCommandEncoder, _ state: any MTLRenderPipelineState,
    _ textures: [any MTLTexture]
  ) {
    encoder.setRenderPipelineState(state)
    for (index, texture) in textures.enumerated() {
      encoder.setFragmentTexture(texture, index: index)
    }
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
  }

  private func drawLight(
    _ encoder: any MTLRenderCommandEncoder, _ resources: PrismResources,
    _ ranges: [(start: Int, count: Int)]
  ) {
    encoder.setRenderPipelineState(resources.light)
    encoder.setCullMode(.none)
    encoder.setVertexBuffer(lightBuffers[lightIndex], offset: 0, index: 0)
    encoder.setVertexBuffer(resources.spectrum, offset: 0, index: 2)
    for range in ranges {
      encoder.drawPrimitives(type: .triangle, vertexStart: range.start, vertexCount: range.count)
    }
  }

  private func drawGlass(
    _ encoder: any MTLRenderCommandEncoder, _ state: any MTLRenderPipelineState,
    _ resources: PrismResources,
    cull: MTLCullMode, _ textures: [any MTLTexture]
  ) {
    encoder.setRenderPipelineState(state)
    encoder.setCullMode(cull)
    encoder.setVertexBuffer(resources.glassVertices, offset: 0, index: 0)
    for (index, texture) in textures.enumerated() {
      encoder.setFragmentTexture(texture, index: index)
    }
    encoder.drawIndexedPrimitives(
      type: .triangle, indexCount: resources.glassIndexCount, indexType: .uint16,
      indexBuffer: resources.glassIndices, indexBufferOffset: 0)
  }

  private func encodeScene(
    _ command: any MTLCommandBuffer, _ resources: PrismResources, _ targets: Targets
  ) {
    let layout = Self.layout
    pass(command, targets.multisample, resolve: targets.backdrop) { encoder in
      drawLight(
        encoder, resources,
        [(0, layout.whiteVertices), (layout.outgoingFirst, layout.outgoingVertices)])
      drawGlass(encoder, resources.glassBack, resources, cull: .front, [resources.environment])
      drawLight(encoder, resources, [(layout.internalFirst, layout.internalVertices)])
    }
    if let blit = command.makeBlitCommandEncoder() {
      blit.generateMipmaps(for: targets.backdrop)
      blit.endEncoding()
    }
    pass(command, targets.multisample, resolve: targets.scene) { encoder in
      fullscreen(encoder, resources.copy, [targets.backdrop])
      drawGlass(
        encoder, resources.glassFront, resources, cull: .back,
        [targets.backdrop, resources.environment])
    }

    let bloom = targets.bloom
    var threshold: Float = 0.1
    pass(command, bloom[0].vertical) { encoder in
      encoder.setFragmentBytes(&threshold, length: 4, index: 0)
      fullscreen(encoder, resources.extract, [targets.scene])
    }
    func blur(_ level: Int, from source: any MTLTexture, horizontal: Bool) {
      let target = horizontal ? bloom[level].horizontal : bloom[level].vertical
      var parameters = Self.bloomKernels[level]
      parameters.direction = horizontal ? SIMD2(1, 0) : SIMD2(0, 1)
      parameters.texel = SIMD2(1 / Float(target.width), 1 / Float(target.height))
      pass(command, target) { encoder in
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<BlurParameters>.stride, index: 0)
        fullscreen(encoder, level < 3 ? resources.packedBlur : resources.wideBlur, [source])
      }
    }
    for level in 0..<3 {
      blur(
        level, from: level == 0 ? bloom[0].vertical : bloom[level - 1].vertical, horizontal: true)
      blur(level, from: bloom[level].horizontal, horizontal: false)
    }
    var downsample = SIMD4<Float>(
      1 / Float(targets.size.x), 1 / Float(targets.size.y),
      Float(targets.size.x) / Float(bloom[3].vertical.width),
      Float(targets.size.y) / Float(bloom[3].vertical.height))
    pass(command, bloom[3].vertical) { encoder in
      encoder.setFragmentBytes(&downsample, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
      fullscreen(encoder, resources.particle, [targets.scene])
    }
    blur(3, from: bloom[3].vertical, horizontal: true)
    blur(3, from: bloom[3].horizontal, horizontal: false)
    pass(command, bloom[0].horizontal) {
      fullscreen(
        $0, resources.composite, [bloom[0].vertical, bloom[1].vertical, bloom[2].vertical])
    }
    pass(command, targets.backdrop) {
      fullscreen($0, resources.present, [targets.scene, bloom[0].horizontal])
    }
    pass(command, targets.presentation) { fullscreen($0, resources.antialias, [targets.backdrop]) }
  }
}
