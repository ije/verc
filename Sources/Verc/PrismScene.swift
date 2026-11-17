import Foundation
import simd

enum PrismScene {
  typealias Vec = SIMD2<Double>

  static let side = 0.57
  static let triangle: [Vec] = [0.0, 120, 240].map {
    Vec(cos($0 * .pi / 180), sin($0 * .pi / 180)) * (side / 3.0.squareRoot())
  }
  static let backZ = 0.015
  static let frontZ = 0.315
  static let lightZ = (backZ + frontZ) / 2
  static let ior = 1.645
  static let dispersion = (base: 1.245, strength: 0.06)
  static let beamWidth = 0.025
  static let lampDistance = 6.5
  static let wavelengths = (min: 400.0, max: 700.0)
  static let exposure = 88.0
  static let inputRadiance = 6.0
  static let edgeFalloff = 16.0
  static let maxBounces = 3
  static let internalSegments = maxBounces + 1
  static let orbitDegrees = 3.5

  static let planes: [SIMD4<Float>] =
    (0..<3).map { edge -> SIMD4<Float> in
      let normal = outwardNormal(triangle[edge], triangle[(edge + 1) % 3])
      return SIMD4(Float(normal.x), Float(normal.y), 0, Float(simd_dot(normal, triangle[edge])))
    } + [SIMD4(0, 0, 1, Float(frontZ)), SIMD4(0, 0, -1, Float(-backZ))]

  static func outwardNormal(_ start: Vec, _ end: Vec) -> Vec {
    let edge = simd_normalize(end - start)
    return Vec(edge.y, -edge.x)
  }

  struct Lamp {
    var center: Vec
    var direction: Vec
    var halfWidth: Double

    init(arc: Double, target: Double) {
      let y = min(1, max(0, arc)) * 2 - 1
      let x = min(1, max(0, target)) * 2 - 1
      let angle = (40 + y * (y < 0 ? 95 : 25)) * .pi / 180
      direction = Vec(cos(angle), sin(angle))
      center =
        simd_mix(triangle[1], triangle[2], Vec(repeating: 0.46 + x * 0.32)) - direction
        * lampDistance
      halfWidth = beamWidth / 2
    }

    func origin(_ profile: Double) -> Vec {
      center + Vec(-direction.y, direction.x) * halfWidth * min(1, max(-1, profile))
    }
  }

  struct Path {
    // Holds maxBounces + 2 points.
    var points: InlineArray<5, Vec>
    var count: Int
    // Packs the hit edges in base 4, so paths with the same key cross the same edges.
    var edges: Int
    var origin: Vec
    var direction: Vec
    var transmission: Double
    var entryTransmission: Double
  }

  private static func cross(_ a: Vec, _ b: Vec) -> Double { a.x * b.y - a.y * b.x }

  private static func intersect(_ origin: Vec, _ direction: Vec, minimum: Double) -> (
    t: Double, normal: Vec, edge: Int
  )? {
    var best: (t: Double, normal: Vec, edge: Int)?
    for index in 0..<3 {
      let start = triangle[index]
      let edge = triangle[(index + 1) % 3] - start
      let denominator = cross(direction, edge)
      if denominator == 0 { continue }
      let offset = start - origin
      let t = cross(offset, edge) / denominator
      let s = cross(offset, direction) / denominator
      if t <= minimum || s < 0 || s > 1 { continue }
      if let best, best.t <= t { continue }
      best = (t, simd_normalize(Vec(edge.y, -edge.x)), index)
    }
    return best
  }

  private static func refract(_ incident: Vec, _ normal: Vec, _ eta: Double) -> Vec? {
    let cosine = -simd_dot(incident, normal)
    let sine = eta * eta * (1 - cosine * cosine)
    if sine > 1 { return nil }
    return incident * eta + normal * (eta * cosine - (1 - sine).squareRoot())
  }

  private static func transmittance(_ incident: Vec, _ normal: Vec, _ from: Double, _ to: Double)
    -> Double
  {
    let cosine = min(1, max(0, -simd_dot(incident, normal)))
    let eta = from / to
    let sine = eta * eta * (1 - cosine * cosine)
    if sine >= 1 { return 0 }
    let transmitted = (1 - sine).squareRoot()
    let s = (from * cosine - to * transmitted) / (from * cosine + to * transmitted)
    let p = (from * transmitted - to * cosine) / (from * transmitted + to * cosine)
    return 1 - 0.5 * (s * s + p * p)
  }

  static func trace(_ origin: Vec, _ direction: Vec, ior: Double) -> Path? {
    guard let entry = intersect(origin, direction, minimum: 1e-4),
      simd_dot(direction, entry.normal) < 0,
      var inside = refract(direction, entry.normal, 1 / ior)
    else { return nil }
    var position = origin + direction * entry.t
    var points = InlineArray<5, Vec>(repeating: position)
    var count = 1
    var edges = entry.edge + 1
    let entryTransmission = transmittance(direction, entry.normal, 1, ior)
    for _ in 0...maxBounces {
      guard let exit = intersect(position, inside, minimum: 1e-4) else { return nil }
      position += inside * exit.t
      points[count] = position
      count += 1
      edges = edges * 4 + exit.edge + 1
      if let transmitted = refract(inside, -exit.normal, ior) {
        return Path(
          points: points, count: count, edges: edges, origin: position,
          direction: simd_normalize(transmitted),
          transmission: entryTransmission * transmittance(inside, -exit.normal, ior, 1),
          entryTransmission: entryTransmission)
      }
      inside -= exit.normal * 2 * simd_dot(inside, exit.normal)
    }
    return nil
  }

  private static let d65: [Double] = [
    82.7549, 91.486, 93.4318, 86.6823, 104.865, 117.008, 117.812, 114.861, 115.923, 108.811,
    109.354,
    107.802, 104.79, 107.689, 104.405, 104.046, 100, 96.3342, 95.788, 88.6856, 90.0062, 89.5991,
    87.6987, 83.2886, 83.6992, 80.0268, 80.2146, 82.2778, 78.2842, 69.7213, 71.6091,
  ]

  static func beamColor(_ wavelength: Double) -> SIMD3<Double> {
    let w = min(wavelengths.max, max(wavelengths.min, wavelength))
    func lobe(_ center: Double, _ below: Double, _ above: Double) -> Double {
      let t = (w - center) * (w < center ? below : above)
      return exp(-0.5 * t * t)
    }
    let x =
      0.362 * lobe(442, 0.0624, 0.0374) + 1.056 * lobe(599.8, 0.0264, 0.0323) - 0.065
      * lobe(501.1, 0.049, 0.0382)
    let y = 0.821 * lobe(568.8, 0.0213, 0.0247) + 0.286 * lobe(530.9, 0.0613, 0.0322)
    let z = 1.217 * lobe(437, 0.0845, 0.0278) + 0.681 * lobe(459, 0.0385, 0.0725)
    var rgb = SIMD3(
      3.2406 * x - 1.5372 * y - 0.4986 * z, -0.9689 * x + 1.8758 * y + 0.0415 * z,
      0.0557 * x - 0.204 * y + 1.057 * z)
    rgb -= min(0, rgb.min())
    let coordinate = min(Double(d65.count - 1), max(0, (w - wavelengths.min) / 10))
    let lower = min(d65.count - 2, Int(coordinate))
    let power =
      (d65[lower] + (d65[lower + 1] - d65[lower]) * (coordinate - Double(lower))) / 100 * y / 1.0347
    let display = (1 - exp(-4.5 * power)) / (1 - exp(-4.5))
    return rgb / max(rgb.max(), .ulpOfOne) * display * SIMD3(1.1868, 1, 2.2495)
  }

  static func wavelength(_ index: Int, of samples: Int) -> Double {
    wavelengths.min + (wavelengths.max - wavelengths.min) * Double(index) / Double(samples - 1)
  }

  struct LightLayout {
    let samples: Int
    let slices: Int
    var whiteQuads: Int { slices }
    var internalQuads: Int { samples * slices * PrismScene.internalSegments }
    var whiteVertices: Int { whiteQuads * 6 }
    var internalFirst: Int { whiteVertices }
    var internalVertices: Int { internalQuads * 6 }
    var outgoingFirst: Int { internalFirst + internalVertices }
    var outgoingVertices: Int { (samples - 1) * slices * 6 }
    var vertexCount: Int { outgoingFirst + outgoingVertices }
  }

  static func buildLight(
    _ layout: LightLayout, lamp: Lamp, wall: Vec, into output: UnsafeMutablePointer<Float>
  ) {
    var cursor = output
    func vertex(_ point: Vec, _ intensity: Double) {
      cursor[0] = Float(point.x)
      cursor[1] = Float(point.y)
      cursor[2] = Float(intensity)
      cursor += 3
    }
    func quad(
      _ lowerStart: Vec, _ upperStart: Vec, _ lowerEnd: Vec, _ upperEnd: Vec, _ start: Double,
      _ end: Double
    ) {
      vertex(lowerStart, start)
      vertex(upperStart, start)
      vertex(upperEnd, end)
      vertex(lowerStart, start)
      vertex(upperEnd, end)
      vertex(lowerEnd, end)
    }
    func empty() { for _ in 0..<6 { vertex(.zero, -1) } }

    let slices = layout.slices
    let samples = layout.samples
    let profiles = (0..<slices).map { -1 + 2 * (Double($0) + 0.5) / Double(slices) }
    let boundaries = (0...slices).map { -1 + 2 * Double($0) / Double(slices) }
    var weights = profiles.map { profile -> Double in
      let edge = min(1, max(0, (abs(profile) - 0.55) / 0.45))
      return exp(-edgeFalloff * profile * profile) * (1 - edge * edge * (3 - 2 * edge))
    }
    let weightSum = weights.reduce(0, +)
    weights = weights.map { $0 / (weightSum > 0 ? weightSum : 1) }

    let white = boundaries.map { profile -> (entry: Vec?, wall: (Vec, Vec)?) in
      let origin = lamp.origin(profile)
      let hit = intersect(origin, lamp.direction, minimum: 1e-4)
      let entry = hit.flatMap {
        simd_dot(lamp.direction, $0.normal) < 0 ? origin + lamp.direction * $0.t : nil
      }
      return (entry, lineThroughWall(origin, lamp.direction, wall))
    }
    for slice in 0..<slices {
      let lower = white[slice]
      let upper = white[slice + 1]
      if let lowerEntry = lower.entry, let upperEntry = upper.entry {
        quad(
          toWall(lowerEntry, -lamp.direction, wall), toWall(upperEntry, -lamp.direction, wall),
          lowerEntry, upperEntry, 0, inputRadiance)
      } else if let lowerWall = lower.wall, let upperWall = upper.wall,
        !beamHits(
          center: lamp.origin((boundaries[slice] + boundaries[slice + 1]) / 2),
          direction: lamp.direction,
          halfWidth: lamp.halfWidth / Double(slices))
      {
        quad(lowerWall.0, upperWall.0, lowerWall.1, upperWall.1, inputRadiance, inputRadiance)
      } else {
        empty()
      }
    }

    let nodes = (0..<samples).map { index -> (paths: [Path?], boundaries: [Path?])? in
      let ior =
        dispersion.base + dispersion.strength / pow(wavelength(index, of: samples) / 1000, 2)
      let paths = profiles.map { trace(lamp.origin($0), lamp.direction, ior: ior) }
      let edges = boundaries.map { trace(lamp.origin($0), lamp.direction, ior: ior) }
      return paths.allSatisfy { $0 == nil } && edges.allSatisfy { $0 == nil } ? nil : (paths, edges)
    }
    let inputWidth = lamp.halfWidth * 2
    func density(_ index: Int, _ profile: Int) -> Double {
      guard let path = nodes[index]?.paths[profile] else { return 0 }
      var left = index - 1
      var right = index + 1
      while left >= 0 && nodes[left]?.paths[profile] == nil { left -= 1 }
      while right < samples && nodes[right]?.paths[profile] == nil { right += 1 }
      if left < 0 { left = index }
      if right >= samples { right = index }
      guard left != right, let leftPath = nodes[left]?.paths[profile],
        let rightPath = nodes[right]?.paths[profile],
        leftPath.edges == rightPath.edges
      else { return 0 }
      let direction = simd_normalize(leftPath.direction + rightPath.direction)
      let width = abs(
        cross(
          rightPath.origin + rightPath.direction - leftPath.origin - leftPath.direction, direction))
      let jacobian = width / (Double(right - left) / Double(samples - 1))
      return exposure * inputWidth * weights[profile] * path.transmission / max(jacobian, 1e-4)
    }
    let densities = (0..<samples).map { index in (0..<slices).map { density(index, $0) } }

    var rgbSum = SIMD3<Double>.zero
    for index in 0..<samples where nodes[index] != nil {
      rgbSum += beamColor(wavelength(index, of: samples))
    }
    let internalScale = inputRadiance / max(rgbSum.max(), 1)
    for node in nodes {
      guard let node else {
        for _ in 0..<(slices * internalSegments) { empty() }
        continue
      }
      for slice in 0..<slices {
        guard let lower = node.boundaries[slice], let upper = node.boundaries[slice + 1],
          lower.edges == upper.edges
        else {
          for _ in 0..<internalSegments { empty() }
          continue
        }
        let intensity = internalScale * (lower.entryTransmission + upper.entryTransmission) / 2
        for segment in 0..<internalSegments {
          if segment + 1 < lower.count {
            quad(
              lower.points[segment], upper.points[segment], lower.points[segment + 1],
              upper.points[segment + 1],
              intensity, intensity)
          } else {
            empty()
          }
        }
      }
    }

    for interval in 0..<(samples - 1) {
      for profile in 0..<slices {
        guard let low = nodes[interval]?.paths[profile],
          let high = nodes[interval + 1]?.paths[profile], low.edges == high.edges
        else {
          empty()
          continue
        }
        let lowEnd = toWall(low.origin, low.direction, wall)
        let highEnd = toWall(high.origin, high.direction, wall)
        let lowDensity = densities[interval][profile]
        let highDensity = densities[interval + 1][profile]
        vertex(low.origin, lowDensity)
        vertex(high.origin, highDensity)
        vertex(highEnd, highDensity)
        vertex(low.origin, lowDensity)
        vertex(highEnd, highDensity)
        vertex(lowEnd, lowDensity)
      }
    }
    assert(cursor == output + layout.vertexCount * 3)
  }

  private static func toWall(_ origin: Vec, _ direction: Vec, _ extent: Vec) -> Vec {
    var nearest = Double.infinity
    for axis in 0..<2 where abs(direction[axis]) >= 1e-8 {
      for side in [-extent[axis], extent[axis]] {
        let distance = (side - origin[axis]) / direction[axis]
        if distance <= 0 || distance >= nearest { continue }
        if abs(origin[1 - axis] + direction[1 - axis] * distance) <= extent[1 - axis] + 1e-6 {
          nearest = distance
        }
      }
    }
    return nearest.isFinite ? origin + direction * nearest : origin
  }

  private static func lineThroughWall(_ origin: Vec, _ direction: Vec, _ extent: Vec) -> (Vec, Vec)?
  {
    var near = -Double.infinity
    var far = Double.infinity
    for axis in 0..<2 {
      if abs(direction[axis]) < 1e-8 {
        if abs(origin[axis]) > extent[axis] { return nil }
        continue
      }
      let first = (-extent[axis] - origin[axis]) / direction[axis]
      let second = (extent[axis] - origin[axis]) / direction[axis]
      near = max(near, min(first, second))
      far = min(far, max(first, second))
      if near > far { return nil }
    }
    near = max(0, near)
    guard near.isFinite, far.isFinite, far >= near else { return nil }
    return (origin + direction * near, origin + direction * far)
  }

  private static func beamHits(center: Vec, direction: Vec, halfWidth: Double) -> Bool {
    let perpendicular = Vec(-direction.y, direction.x)
    var polygon = triangle.map {
      Vec(simd_dot($0 - center, direction), simd_dot($0 - center, perpendicular))
    }
    for inside in [
      { (p: Vec) in p.x }, { (p: Vec) in p.y + halfWidth }, { (p: Vec) in halfWidth - p.y },
    ] {
      let input = polygon
      polygon = []
      for (index, start) in input.enumerated() {
        let end = input[(index + 1) % input.count]
        let a = inside(start)
        let b = inside(end)
        if a >= 0 { polygon.append(start) }
        if (a >= 0) != (b >= 0) { polygon.append(start + (end - start) * (a / (a - b))) }
      }
      if polygon.isEmpty { return false }
    }
    return true
  }

  static func glassMesh() -> (vertices: [Float], indices: [UInt16]) {
    let radius = min(0.008, (frontZ - backZ) * 0.45)
    var contour: [(position: Vec, normal: Vec)] = []
    let arcs = (0..<3).map { index -> [(position: Vec, normal: Vec)] in
      let corner = triangle[index]
      let previous = simd_normalize(triangle[(index + 2) % 3] - corner)
      let next = simd_normalize(triangle[(index + 1) % 3] - corner)
      let half = acos(min(1, max(-1, simd_dot(previous, next)))) / 2
      let center = corner + simd_normalize(previous + next) * radius / max(sin(half), 1e-6)
      let start = corner + previous * radius / max(tan(half), 1e-6) - center
      let end = corner + next * radius / max(tan(half), 1e-6) - center
      let from = atan2(start.y, start.x)
      var to = atan2(end.y, end.x)
      while to <= from { to += 2 * .pi }
      return (0...4).map { step in
        let angle = from + (to - from) * Double(step) / 4
        let normal = Vec(cos(angle), sin(angle))
        return (center + normal * radius, normal)
      }
    }
    for index in 0..<3 {
      contour += arcs[index]
      let end = arcs[index].last!.position
      let next = arcs[(index + 1) % 3][0].position
      let normal = outwardNormal(triangle[index], triangle[(index + 1) % 3])
      contour += (1..<16).map { (end + (next - end) * Double($0) / 16, normal) }
    }

    var vertices: [Float] = []
    var indices: [UInt16] = []
    var rings: [[UInt16]] = []
    func push(_ position: SIMD3<Double>, _ normal: SIMD3<Double>) -> UInt16 {
      defer {
        vertices += [position.x, position.y, position.z, normal.x, normal.y, normal.z].map {
          Float($0)
        }
      }
      return UInt16(vertices.count / 6)
    }
    let maxTheta = Double.pi / 2 - 0.06
    func ring(_ theta: Double, _ z: Double, _ zNormal: Double) {
      let inset = radius * (1 - cos(theta))
      rings.append(
        contour.map {
          push(SIMD3($0.position - $0.normal * inset, z), SIMD3($0.normal * cos(theta), zNormal))
        })
    }
    for step in stride(from: 4, through: 0, by: -1) {
      let theta = maxTheta * Double(step) / 4
      ring(theta, backZ + radius - radius * sin(theta) / sin(maxTheta), -sin(theta))
    }
    for step in 0...4 {
      let theta = maxTheta * Double(step) / 4
      ring(theta, frontZ - radius + radius * sin(theta) / sin(maxTheta), sin(theta))
    }
    for band in 0..<(rings.count - 1) {
      let current = rings[band]
      let next = rings[band + 1]
      for point in contour.indices {
        let following = (point + 1) % contour.count
        indices += [
          current[point], current[following], next[following], current[point], next[following],
          next[point],
        ]
      }
    }
    for (source, z, reverse) in [(rings[0], -1.0, true), (rings[rings.count - 1], 1.0, false)] {
      let cap = source.map { index -> UInt16 in
        let base = Int(index) * 6
        return push(
          SIMD3(Double(vertices[base]), Double(vertices[base + 1]), Double(vertices[base + 2])),
          SIMD3(0, 0, z))
      }
      let points = cap.map {
        SIMD3(
          Double(vertices[Int($0) * 6]), Double(vertices[Int($0) * 6 + 1]),
          Double(vertices[Int($0) * 6 + 2]))
      }
      let center = push(points.reduce(.zero, +) / Double(points.count), SIMD3(0, 0, z))
      for point in cap.indices {
        let following = (point + 1) % cap.count
        indices +=
          reverse ? [center, cap[following], cap[point]] : [center, cap[point], cap[following]]
      }
    }
    return (vertices, indices)
  }

  struct Camera {
    var viewProjection: simd_float4x4
    var position: SIMD3<Float>
    var wall: Vec
  }

  static let cameraDistance = 1.5
  static let cameraTarget = SIMD3((triangle[0].x + triangle[1].x) / 2, 0, 0)

  static func view(aspect: Double, orbit: Vec) -> (
    viewProjection: simd_double4x4, position: SIMD3<Double>, forward: SIMD3<Double>,
    right: SIMD3<Double>, up: SIMD3<Double>, focal: Double
  ) {
    let yaw = min(1, max(-1, orbit.x)) * orbitDegrees * .pi / 180
    let pitch = -min(1, max(-1, orbit.y)) * orbitDegrees * .pi / 180
    let position =
      cameraTarget + SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
      * cameraDistance
    let forward = simd_normalize(cameraTarget - position)
    let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
    let up = simd_cross(right, forward)
    let view = simd_double4x4(rows: [
      SIMD4(right, -simd_dot(right, position)), SIMD4(up, -simd_dot(up, position)),
      SIMD4(-forward, simd_dot(forward, position)), SIMD4(0, 0, 0, 1),
    ])
    let focal = 0.8 / tan(24 * .pi / 180) * min(1, aspect / 1.2)
    let near = 0.05
    let far = 10.0
    let range = 1 / (near - far)
    let projection = simd_double4x4(
      columns: (
        SIMD4(focal / aspect, 0, 0, 0), SIMD4(0, focal, 0, 0),
        SIMD4(0, 0, far * range, -1), SIMD4(0, 0, far * near * range, 0)
      ))
    return (projection * view, position, forward, right, up, focal)
  }

  static func camera(aspect: Double, orbit: Vec) -> Camera {
    let current = view(aspect: aspect, orbit: orbit)
    var worst = 0.0
    for x in [-1.0, 0, 1] {
      for y in [-1.0, 0, 1] {
        let corner = view(aspect: aspect, orbit: Vec(x, y))
        for horizontal in [-1.0, 1] {
          for vertical in [-1.0, 1] {
            let direction =
              corner.forward + (corner.right * horizontal * aspect + corner.up * vertical)
              / corner.focal
            let t = -corner.position.z / direction.z
            worst = max(
              worst, abs(corner.position.x + direction.x * t) / aspect,
              abs(corner.position.y + direction.y * t))
          }
        }
      }
    }
    let matrix = current.viewProjection
    return Camera(
      viewProjection: simd_float4x4(
        SIMD4<Float>(matrix.columns.0), SIMD4<Float>(matrix.columns.1),
        SIMD4<Float>(matrix.columns.2), SIMD4<Float>(matrix.columns.3)),
      position: SIMD3<Float>(current.position), wall: Vec(worst * 1.02 * aspect, worst * 1.02))
  }
}
