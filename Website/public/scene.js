export const triangle = [0, 120, 240].map((angle) => [
  (Math.cos((angle * Math.PI) / 180) * 0.57) / Math.sqrt(3),
  (Math.sin((angle * Math.PI) / 180) * 0.57) / Math.sqrt(3),
]);
export const planes = triangle
  .map((a, index) => {
    const b = triangle[(index + 1) % 3],
      dx = b[0] - a[0],
      dy = b[1] - a[1],
      length = Math.hypot(dx, dy);
    return [dy / length, -dx / length, 0, (dy * a[0] - dx * a[1]) / length];
  })
  .concat([
    [0, 0, 1, 0.315],
    [0, 0, -1, -0.015],
  ]);

const dot = (a, b) => a[0] * b[0] + a[1] * b[1];
const cross = (a, b) => a[0] * b[1] - a[1] * b[0];
const add = (a, b, scale = 1) => [a[0] + b[0] * scale, a[1] + b[1] * scale];
const unit = (a) => {
  const length = Math.hypot(...a);
  return a.map((x) => x / length);
};

function intersect(origin, direction) {
  let nearest;
  for (let index = 0; index < 3; index++) {
    const start = triangle[index],
      edge = add(triangle[(index + 1) % 3], start, -1);
    const denominator = cross(direction, edge);
    if (Math.abs(denominator) < 1e-10) continue;
    const offset = add(start, origin, -1),
      distance = cross(offset, edge) / denominator,
      t = cross(offset, direction) / denominator;
    if (
      distance <= 1e-4 ||
      t < 0 ||
      t > 1 ||
      (nearest && nearest.distance <= distance)
    )
      continue;
    nearest = { distance, normal: planes[index].slice(0, 2), edge: index };
  }
  return nearest;
}

function refract(incident, normal, eta) {
  const cosine = -dot(incident, normal),
    sine = eta * eta * (1 - cosine * cosine);
  return sine > 1
    ? null
    : add(
        incident.map((x) => x * eta),
        normal,
        eta * cosine - Math.sqrt(1 - sine),
      );
}

function transmittance(incident, normal, from, to) {
  const cosine = Math.min(1, Math.max(0, -dot(incident, normal))),
    sine = (from / to) ** 2 * (1 - cosine * cosine);
  if (sine >= 1) return 0;
  const transmitted = Math.sqrt(1 - sine);
  return (
    1 -
    0.5 *
      (((from * cosine - to * transmitted) /
        (from * cosine + to * transmitted)) **
        2 +
        ((from * transmitted - to * cosine) /
          (from * transmitted + to * cosine)) **
          2)
  );
}

function trace(origin, direction, ior) {
  const entry = intersect(origin, direction);
  if (!entry || dot(direction, entry.normal) >= 0) return null;
  let inside = refract(direction, entry.normal, 1 / ior);
  if (!inside) return null;
  let position = add(origin, direction, entry.distance);
  const points = [position],
    edges = [entry.edge],
    entryTransmission = transmittance(direction, entry.normal, 1, ior);
  for (let bounce = 0; bounce <= 3; bounce++) {
    const exit = intersect(position, inside);
    if (!exit) return null;
    position = add(position, inside, exit.distance);
    points.push(position);
    edges.push(exit.edge);
    const inward = exit.normal.map((x) => -x),
      transmitted = refract(inside, inward, ior);
    if (transmitted)
      return {
        points,
        edges: edges.join(),
        origin: position,
        direction: unit(transmitted),
        transmission: entryTransmission * transmittance(inside, inward, ior, 1),
        entryTransmission,
      };
    inside = add(inside, exit.normal, -2 * dot(inside, exit.normal));
  }
  return null;
}

const d65 = [
  82.7549, 91.486, 93.4318, 86.6823, 104.865, 117.008, 117.812, 114.861,
  115.923, 108.811, 109.354, 107.802, 104.79, 107.689, 104.405, 104.046, 100,
  96.3342, 95.788, 88.6856, 90.0062, 89.5991, 87.6987, 83.2886, 83.6992,
  80.0268, 80.2146, 82.2778, 78.2842, 69.7213, 71.6091,
];

function lobe(w, center, below, above) {
  return Math.exp(-0.5 * ((w - center) * (w < center ? below : above)) ** 2);
}

const samples = 128,
  slices = 24,
  internalSegments = 4;
export const lightLayout = {
  samples,
  slices,
  whiteVertices: slices * 6,
  internalVertices: samples * slices * internalSegments * 6,
  outgoingFirst: (slices + samples * slices * internalSegments) * 6,
  outgoingVertices: (samples - 1) * slices * 6,
  vertexCount:
    (slices + samples * slices * internalSegments + (samples - 1) * slices) * 6,
};
const boundaries = Array.from(
  { length: slices + 1 },
  (_, i) => -1 + (2 * i) / slices,
);
const profiles = Array.from(
  { length: slices },
  (_, i) => -1 + (2 * (i + 0.5)) / slices,
);
const weights = profiles.map((profile) => {
  const edge = Math.min(1, Math.max(0, (Math.abs(profile) - 0.55) / 0.45));
  return Math.exp(-16 * profile * profile) * (1 - edge * edge * (3 - 2 * edge));
});
const weightSum = weights.reduce((a, b) => a + b, 0);
for (let index = 0; index < slices; index++) weights[index] /= weightSum;
const colors = Array.from({ length: samples }, (_, i) => {
  const wavelength = 400 + (300 * i) / (samples - 1);
  const x =
    0.362 * lobe(wavelength, 442, 0.0624, 0.0374) +
    1.056 * lobe(wavelength, 599.8, 0.0264, 0.0323) -
    0.065 * lobe(wavelength, 501.1, 0.049, 0.0382);
  const y =
    0.821 * lobe(wavelength, 568.8, 0.0213, 0.0247) +
    0.286 * lobe(wavelength, 530.9, 0.0613, 0.0322);
  const z =
    1.217 * lobe(wavelength, 437, 0.0845, 0.0278) +
    0.681 * lobe(wavelength, 459, 0.0385, 0.0725);
  let color = [
    3.2406 * x - 1.5372 * y - 0.4986 * z,
    -0.9689 * x + 1.8758 * y + 0.0415 * z,
    0.0557 * x - 0.204 * y + 1.057 * z,
  ];
  const minimum = Math.min(0, ...color);
  color = color.map((x) => x - minimum);
  const coordinate = (wavelength - 400) / 10,
    lower = Math.min(29, Math.floor(coordinate));
  const power =
    (((d65[lower] + (d65[lower + 1] - d65[lower]) * (coordinate - lower)) /
      100) *
      y) /
    1.0347;
  const scale =
    (1 - Math.exp(-4.5 * power)) /
    (1 - Math.exp(-4.5)) /
    Math.max(...color, 1e-10);
  return color.map((x, i) => x * scale * [1.1868, 1, 2.2495][i]);
});
export const spectrum = new Float32Array(
  colors.flatMap((color) => [...color, 0]),
);

function toWall(origin, direction, extent) {
  let nearest = Infinity;
  for (let axis = 0; axis < 2; axis++) {
    if (Math.abs(direction[axis]) < 1e-8) continue;
    for (const side of [-extent[axis], extent[axis]]) {
      const distance = (side - origin[axis]) / direction[axis];
      if (distance <= 0 || distance >= nearest) continue;
      if (
        Math.abs(origin[1 - axis] + direction[1 - axis] * distance) <=
        extent[1 - axis] + 1e-6
      )
        nearest = distance;
    }
  }
  return Number.isFinite(nearest) ? add(origin, direction, nearest) : origin;
}

export function buildLight(aim, wall, vertices) {
  const y = Math.min(1, Math.max(0, aim[0])) * 2 - 1,
    x = Math.min(1, Math.max(0, aim[1])) * 2 - 1;
  const angle = ((40 + y * (y < 0 ? 95 : 25)) * Math.PI) / 180;
  const direction = [Math.cos(angle), Math.sin(angle)],
    perpendicular = [-direction[1], direction[0]];
  const center = add(
    add(triangle[1], add(triangle[2], triangle[1], -1), 0.46 + x * 0.32),
    direction,
    -6.5,
  );
  const origins = boundaries.map((profile) =>
    add(center, perpendicular, 0.0125 * profile),
  );
  let cursor = 0;
  function vertex(point, intensity) {
    vertices[cursor++] = point[0];
    vertices[cursor++] = point[1];
    vertices[cursor++] = intensity;
  }
  function quad(a, b, c, d, start, end) {
    vertex(a, start);
    vertex(b, start);
    vertex(d, end);
    vertex(a, start);
    vertex(d, end);
    vertex(c, end);
  }
  function empty() {
    for (let index = 0; index < 6; index++) vertex([0, 0], -1);
  }
  const white = origins.map((origin) => {
    const hit = intersect(origin, direction);
    const entry =
      hit && dot(direction, hit.normal) < 0
        ? add(origin, direction, hit.distance)
        : null;
    let near = -Infinity,
      far = Infinity;
    for (let axis = 0; axis < 2; axis++) {
      if (Math.abs(direction[axis]) < 1e-8) {
        if (Math.abs(origin[axis]) > wall[axis]) return { entry, wall: null };
        continue;
      }
      const first = (-wall[axis] - origin[axis]) / direction[axis],
        second = (wall[axis] - origin[axis]) / direction[axis];
      near = Math.max(near, Math.min(first, second));
      far = Math.min(far, Math.max(first, second));
      if (near > far) return { entry, wall: null };
    }
    near = Math.max(0, near);
    return {
      entry,
      wall:
        Number.isFinite(near) && Number.isFinite(far) && far >= near
          ? [add(origin, direction, near), add(origin, direction, far)]
          : null,
    };
  });
  for (let slice = 0; slice < slices; slice++) {
    const low = white[slice],
      high = white[slice + 1];
    if (low.entry && high.entry) {
      const reverse = direction.map((x) => -x);
      quad(
        toWall(low.entry, reverse, wall),
        toWall(high.entry, reverse, wall),
        low.entry,
        high.entry,
        0,
        6,
      );
    } else if (low.wall && high.wall) {
      const origin = add(center, perpendicular, 0.0125 * profiles[slice]),
        halfWidth = 0.0125 / slices;
      let polygon = triangle.map((point) => {
        const offset = add(point, origin, -1);
        return [dot(offset, direction), dot(offset, perpendicular)];
      });
      for (let plane = 0; plane < 3; plane++) {
        const input = polygon;
        polygon = [];
        for (let index = 0; index < input.length; index++) {
          const start = input[index],
            end = input[(index + 1) % input.length];
          const a =
            plane === 0
              ? start[0]
              : halfWidth + start[1] * (plane === 1 ? 1 : -1);
          const b =
            plane === 0 ? end[0] : halfWidth + end[1] * (plane === 1 ? 1 : -1);
          if (a >= 0) polygon.push(start);
          if (a >= 0 !== b >= 0)
            polygon.push(add(start, add(end, start, -1), a / (a - b)));
        }
        if (!polygon.length) break;
      }
      if (!polygon.length)
        quad(low.wall[0], high.wall[0], low.wall[1], high.wall[1], 6, 6);
      else empty();
    } else empty();
  }
  const nodes = Array.from({ length: samples }, (_, index) => {
    const ior =
      1.245 + 0.06 / ((400 + (300 * index) / (samples - 1)) / 1000) ** 2;
    const paths = profiles.map((profile) =>
      trace(add(center, perpendicular, 0.0125 * profile), direction, ior),
    );
    const edges = origins.map((origin) => trace(origin, direction, ior));
    return paths.some(Boolean) || edges.some(Boolean)
      ? { paths, boundaries: edges }
      : null;
  });
  const densities = nodes.map((node, index) =>
    profiles.map((_, slice) => {
      const path = node?.paths[slice];
      if (!path) return 0;
      let left = index - 1,
        right = index + 1;
      while (left >= 0 && !nodes[left]?.paths[slice]) left--;
      while (right < samples && !nodes[right]?.paths[slice]) right++;
      if (left < 0) left = index;
      if (right >= samples) right = index;
      const low = nodes[left]?.paths[slice],
        high = nodes[right]?.paths[slice];
      if (left === right || !low || !high || low.edges !== high.edges) return 0;
      const width = Math.abs(
        cross(
          add(
            add(high.origin, high.direction),
            add(low.origin, low.direction),
            -1,
          ),
          unit(add(low.direction, high.direction)),
        ),
      );
      return (
        (88 * 0.025 * weights[slice] * path.transmission) /
        Math.max(width / ((right - left) / (samples - 1)), 1e-4)
      );
    }),
  );
  const totals = [0, 0, 0];
  nodes.forEach((node, index) => {
    if (node)
      colors[index].forEach((value, channel) => (totals[channel] += value));
  });
  const internalScale = 6 / Math.max(...totals, 1);
  for (const node of nodes) {
    for (let slice = 0; slice < slices; slice++) {
      const low = node?.boundaries[slice],
        high = node?.boundaries[slice + 1];
      const valid = low && high && low.edges === high.edges;
      const intensity = valid
        ? (internalScale * (low.entryTransmission + high.entryTransmission)) / 2
        : 0;
      for (let segment = 0; segment < internalSegments; segment++) {
        if (valid && segment + 1 < low.points.length) {
          quad(
            low.points[segment],
            high.points[segment],
            low.points[segment + 1],
            high.points[segment + 1],
            intensity,
            intensity,
          );
        } else empty();
      }
    }
  }
  for (let index = 0; index < samples - 1; index++) {
    for (let slice = 0; slice < slices; slice++) {
      const low = nodes[index]?.paths[slice],
        high = nodes[index + 1]?.paths[slice];
      if (!low || !high || low.edges !== high.edges) {
        empty();
        continue;
      }
      const lowEnd = toWall(low.origin, low.direction, wall),
        highEnd = toWall(high.origin, high.direction, wall);
      vertex(low.origin, densities[index][slice]);
      vertex(high.origin, densities[index + 1][slice]);
      vertex(highEnd, densities[index + 1][slice]);
      vertex(low.origin, densities[index][slice]);
      vertex(highEnd, densities[index + 1][slice]);
      vertex(lowEnd, densities[index][slice]);
    }
  }
}

export function view(aspect, orbit) {
  const yaw = (Math.min(1, Math.max(-1, orbit[0])) * 3.5 * Math.PI) / 180,
    pitch = (-Math.min(1, Math.max(-1, orbit[1])) * 3.5 * Math.PI) / 180;
  const back = [
    Math.sin(yaw) * Math.cos(pitch),
    Math.sin(pitch),
    Math.cos(yaw) * Math.cos(pitch),
  ];
  const right = [Math.cos(yaw), 0, -Math.sin(yaw)],
    up = [
      -Math.sin(yaw) * Math.sin(pitch),
      Math.cos(pitch),
      -Math.cos(yaw) * Math.sin(pitch),
    ];
  const position = back.map(
    (x, index) =>
      x * 1.5 + (index === 0 ? (triangle[0][0] + triangle[1][0]) / 2 : 0),
  );
  const focal =
      (0.8 / Math.tan((24 * Math.PI) / 180)) * Math.min(1, aspect / 1.2),
    range = 1 / (0.05 - 10),
    matrix = new Float32Array(16);
  for (let column = 0; column < 3; column++)
    matrix.set(
      [
        (focal / aspect) * right[column],
        focal * up[column],
        10 * range * back[column],
        -back[column],
      ],
      column * 4,
    );
  matrix.set(
    [
      (-focal / aspect) * right.reduce((sum, x, i) => sum + x * position[i], 0),
      -focal * up.reduce((sum, x, i) => sum + x * position[i], 0),
      -10 * range * back.reduce((sum, x, i) => sum + x * position[i], 0) +
        0.5 * range,
      back.reduce((sum, x, i) => sum + x * position[i], 0),
    ],
    12,
  );
  return { matrix, position, forward: back.map((x) => -x), right, up, focal };
}

export function glassMesh() {
  const radius = 0.008,
    contour = [],
    vertices = [],
    indices = [],
    rings = [];
  const arcs = triangle.map((corner, index) => {
    const previous = unit(add(triangle[(index + 2) % 3], corner, -1)),
      next = unit(add(triangle[(index + 1) % 3], corner, -1));
    const half = Math.acos(dot(previous, next)) / 2;
    const center = add(
      corner,
      unit(add(previous, next)),
      radius / Math.sin(half),
    );
    const start = add(
        add(corner, previous, radius / Math.tan(half)),
        center,
        -1,
      ),
      end = add(add(corner, next, radius / Math.tan(half)), center, -1);
    const from = Math.atan2(start[1], start[0]);
    let to = Math.atan2(end[1], end[0]);
    while (to <= from) to += 2 * Math.PI;
    return Array.from({ length: 5 }, (_, step) => {
      const angle = from + ((to - from) * step) / 4,
        normal = [Math.cos(angle), Math.sin(angle)];
      return { position: add(center, normal, radius), normal };
    });
  });
  for (let index = 0; index < 3; index++) {
    contour.push(...arcs[index]);
    const end = arcs[index][4].position,
      next = arcs[(index + 1) % 3][0].position;
    for (let step = 1; step < 16; step++)
      contour.push({
        position: add(end, add(next, end, -1), step / 16),
        normal: planes[index].slice(0, 2),
      });
  }
  const maxTheta = Math.PI / 2 - 0.06;
  for (let band = 0; band < 10; band++) {
    const front = band >= 5,
      step = front ? band - 5 : 4 - band,
      theta = (maxTheta * step) / 4;
    const z = front
      ? 0.315 - radius + (radius * Math.sin(theta)) / Math.sin(maxTheta)
      : 0.015 + radius - (radius * Math.sin(theta)) / Math.sin(maxTheta);
    const ring = [];
    for (const point of contour) {
      ring.push(vertices.length / 6);
      vertices.push(
        ...add(point.position, point.normal, -radius * (1 - Math.cos(theta))),
        z,
        point.normal[0] * Math.cos(theta),
        point.normal[1] * Math.cos(theta),
        Math.sin(theta) * (front ? 1 : -1),
      );
    }
    rings.push(ring);
  }
  for (let band = 0; band < rings.length - 1; band++) {
    for (let point = 0; point < contour.length; point++) {
      const next = (point + 1) % contour.length,
        a = rings[band],
        b = rings[band + 1];
      indices.push(a[point], a[next], b[next], a[point], b[next], b[point]);
    }
  }
  for (const [ring, normal] of [
    [rings[0], -1],
    [rings[9], 1],
  ]) {
    const cap = [],
      center = [0, 0, 0];
    for (const point of ring) {
      const position = vertices.slice(point * 6, point * 6 + 3);
      position.forEach((x, i) => (center[i] += x / ring.length));
      cap.push(vertices.length / 6);
      vertices.push(...position, 0, 0, normal);
    }
    const middle = vertices.length / 6;
    vertices.push(...center, 0, 0, normal);
    for (let point = 0; point < cap.length; point++) {
      const next = (point + 1) % cap.length;
      indices.push(
        middle,
        cap[normal < 0 ? next : point],
        cap[normal < 0 ? point : next],
      );
    }
  }
  return {
    vertices: new Float32Array(vertices),
    indices: new Uint16Array(indices),
  };
}
