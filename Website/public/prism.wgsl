struct Scene {
    viewProjection: mat4x4f,
    camera: vec4f,
    output: vec4f,
    timing: vec4f,
    planes: array<vec4f, 5>,
    // Front corner UVs for dust, with the light z in the last lane.
    prism: array<vec4f, 2>,
    lightLayout: vec4u,
}
@group(0) @binding(0) var<uniform> scene: Scene;
@group(0) @binding(1) var<uniform> spectrum: array<vec4f, 128>;
@group(1) @binding(0) var linearSampler: sampler;
@group(1) @binding(1) var source: texture_2d<f32>;
@group(1) @binding(2) var bloom0: texture_2d<f32>;
@group(1) @binding(3) var bloom1: texture_2d<f32>;
@group(1) @binding(4) var bloom2: texture_2d<f32>;
@group(1) @binding(5) var<uniform> blur: vec4f;

fn tonemap(value: vec3f) -> vec3f {
    return clamp((value * (2.51 * value + .03)) / (value * (2.43 * value + .59) + .14), vec3f(0), vec3f(1));
}
fn toSrgb(value: vec3f) -> vec3f {
    return select(1.055 * pow(max(value, vec3f(0)), vec3f(1.0 / 2.4)) - .055, value * 12.92, value <= vec3f(.0031308));
}
fn panel(direction: vec3f, position: vec3f, size: vec2f, feather: f32) -> f32 {
    let forward = normalize(position);
    let helper = select(vec3f(0, 1, 0), vec3f(0, 0, 1), abs(forward.y) > .92);
    let right = normalize(cross(helper, forward));
    let up = cross(forward, right);
    let facing = dot(direction, forward);
    if (facing <= .01) { return 0; }
    let local = abs(vec2f(dot(direction, right), dot(direction, up)) / facing);
    let edge = 1 - smoothstep(size, size + feather, local);
    return edge.x * edge.y;
}
fn environment(direction: vec3f) -> vec3f {
    let d = normalize(direction);
    let floorBlend = 1 - smoothstep(-.22, -.02, d.y);
    var room = mix(vec3f(.00025, .0003, .0004), vec3f(.006, .007, .009), floorBlend);
    let backWall = (1 - smoothstep(-.08, .08, d.z)) * smoothstep(-.28, -.08, d.y);
    room = mix(room, vec3f(.00002), backWall);
    let horizon = exp(-abs(d.y + .1) * 22) * .0012;
    var color = room + vec3f(horizon, horizon * .96, horizon * .9);
    color += vec3f(.82, .84, .88) * panel(d, vec3f(-.82, .08, .57), vec2f(1.35, 1.1), .22) * .011;
    color += vec3f(1, .97, .91) * panel(d, vec3f(0, -.707, .707), vec2f(.38, .62), .18) * .22;
    color += vec3f(.76, .88, 1) * panel(d, vec3f(.612, .354, .707), vec2f(.5, .16), .035) * 20;
    let mapped = pow(max(color / (1 + color), vec3f(0)), vec3f(1.0 / 2.2));
    return select(pow((mapped + .055) / 1.055, vec3f(2.4)), mapped / 12.92, mapped <= vec3f(.04045)) * 2.3;
}
fn fresnel(facing: f32) -> f32 {
    let grazing = 1 - clamp(facing, 0, 1);
    return .059466 + (1 - .059466) * pow(grazing, 5);
}
fn exitFresnel(facing: f32) -> f32 {
    return fresnel(sqrt(max(1 - 1.645 * 1.645 * (1 - facing * facing), 0)));
}

struct ScreenVertex { @builtin(position) position: vec4f, @location(0) uv: vec2f }
@vertex fn screenVertex(@builtin(vertex_index) id: u32) -> ScreenVertex {
    let uv = vec2f(f32((id << 1u) & 2u), f32(id & 2u));
    return ScreenVertex(vec4f(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1), uv);
}
struct LightVertex {
    @builtin(position) position: vec4f,
    @location(0) @interpolate(perspective, centroid) color: vec3f,
    @location(1) @interpolate(perspective, centroid) profile: f32,
    @location(2) @interpolate(perspective, centroid) intensity: f32,
    @location(3) @interpolate(perspective, centroid) travel: f32,
}
@vertex fn lightVertex(@builtin(vertex_index) id: u32, @location(0) data: vec3f) -> LightVertex {
    let quad = id / 6u;
    let corner = id % 6u;
    let upper = (22u >> corner) & 1u;
    let slices = scene.lightLayout.y;
    let white = quad < scene.lightLayout.x;
    var profile = 0.0;
    var travel = 0.0;
    var spectral = 0u;
    if (white) {
        profile = -1 + 2 * f32(quad + upper) / f32(slices);
    } else if (quad - scene.lightLayout.x < scene.lightLayout.w) {
        let spectralQuad = quad - scene.lightLayout.x;
        spectral = spectralQuad / (slices * 4u);
        profile = -1 + 2 * f32((spectralQuad % (slices * 4u)) / 4u + upper) / f32(slices);
    } else {
        spectral = (quad - scene.lightLayout.x - scene.lightLayout.w) / slices + upper;
        travel = f32((52u >> corner) & 1u);
    }
    var color = vec3f(1);
    if (!white && data.z >= 0) { color = spectrum[min(spectral, scene.lightLayout.z - 1u)].rgb; }
    return LightVertex(scene.viewProjection * vec4f(data.xy, .165, 1), color, profile, max(data.z, 0), travel);
}
@fragment fn lightFragment(in: LightVertex) -> @location(0) vec4f {
    let radius = abs(in.profile);
    let radial = exp(-16 * radius * radius) * (1 - smoothstep(.55, 1, radius));
    let falloff = 1 / pow(1 + 3.8 * max(in.travel, 0), 3.7);
    return vec4f(in.color * in.intensity * radial * falloff, 0);
}
struct GlassVertex {
    @builtin(position) position: vec4f,
    @location(0) @interpolate(perspective, sample) world: vec3f,
    @location(1) @interpolate(perspective, sample) normal: vec3f,
}
@vertex fn glassVertex(@location(0) position: vec3f, @location(1) normal: vec3f) -> GlassVertex {
    return GlassVertex(scene.viewProjection * vec4f(position, 1), position, normal);
}
struct Hit { normal: vec3f, distance: f32, plane: u32 }
fn nextSurface(origin: vec3f, direction: vec3f, departed: u32) -> Hit {
    var result = Hit(vec3f(0, 0, 1), 100000, departed);
    let order = array<u32, 5>(3, 4, 0, 1, 2);
    for (var index = 0u; index < 5u; index++) {
        let candidate = order[index];
        if (candidate == departed) { continue; }
        let plane = scene.planes[candidate];
        let denominator = dot(plane.xyz, direction);
        if (denominator <= .00001) { continue; }
        let distance = (plane.w - dot(plane.xyz, origin)) / denominator;
        if (distance >= 0 && distance < result.distance) { result = Hit(plane.xyz, distance, candidate); }
    }
    return result;
}
struct Exit { position: vec3f, direction: vec3f, incident: vec3f, normal: vec3f, escaped: bool, plane: u32 }
fn traceExit(position: vec3f, direction: vec3f, normal: vec3f, plane: u32) -> Exit {
    var result = Exit(position, direction, direction, normal, false, plane);
    for (var bounce = 0; bounce <= 3; bounce++) {
        let transmitted = refract(result.incident, result.normal, 1.645);
        if (length(transmitted) > .00001) {
            result.direction = normalize(transmitted);
            result.escaped = true;
            return result;
        }
        result.incident = reflect(result.incident, result.normal);
        result.direction = result.incident;
        let hit = nextSurface(result.position, result.incident, result.plane);
        if (hit.distance >= 10) { break; }
        result.position += result.incident * hit.distance;
        result.plane = hit.plane;
        result.normal = -hit.normal;
    }
    return result;
}
fn backSurface(position: vec3f, normal: vec3f) -> vec4f {
    let incident = -normalize(scene.camera.xyz - position);
    let exit = traceExit(position, incident, -normalize(normal), 5u);
    let reflected = reflect(exit.incident, exit.normal);
    let hit = nextSurface(exit.position, reflected, exit.plane);
    var reflectedExit = Exit(exit.position, reflected, reflected, exit.normal, false, exit.plane);
    if (hit.distance < 10) { reflectedExit = traceExit(exit.position + reflected * hit.distance, reflected, -hit.normal, hit.plane); }
    let facing = clamp(-dot(reflectedExit.incident, reflectedExit.normal), 0, 1);
    let transmission = select(0, 1 - exitFresnel(facing), reflectedExit.escaped);
    let color = environment(reflectedExit.direction) * 2.14 * transmission;
    let weight = select(1, exitFresnel(clamp(-dot(exit.incident, exit.normal), 0, 1)), exit.escaped);
    return vec4f(color * weight, weight);
}
// Total internal reflection changes within a pixel along the back bevel.
@fragment fn glassBack(in: GlassVertex) -> @location(0) vec4f {
    let positionDx = dpdx(in.world);
    let positionDy = dpdy(in.world);
    let normalDx = dpdx(in.normal);
    let normalDy = dpdy(in.normal);
    if (length(normalDx) + length(normalDy) < .05) { return backSurface(in.world, in.normal); }
    let offsets = array<vec2f, 8>(vec2f(.03125, -.09375), vec2f(-.03125, .09375), vec2f(.15625, .03125), vec2f(-.09375, -.15625),
        vec2f(-.15625, .15625), vec2f(-.21875, -.03125), vec2f(.09375, .21875), vec2f(.21875, -.21875));
    var sum = vec4f(0);
    for (var index = 0; index < 8; index++) {
        let offset = offsets[index];
        sum += backSurface(in.world + positionDx * offset.x + positionDy * offset.y, in.normal + normalDx * offset.x + normalDy * offset.y);
    }
    return sum * .125;
}
@fragment fn glassFront(in: GlassVertex) -> @location(0) vec4f {
    let normal = normalize(in.normal);
    let view = normalize(scene.camera.xyz - in.world);
    let facing = clamp(dot(view, normal), 0, 1);
    let reflectedEnvironment = environment(reflect(-view, normal));
    let weight = fresnel(facing);
    let inside = normalize(refract(-view, normal, 1 / 1.645));
    let shifted = in.world + inside * .0002;
    let hit = nextSurface(shifted, inside, 5u);
    let valid = hit.distance < 10;
    let distance = select(0, hit.distance, valid);
    let clip = scene.viewProjection * vec4f(shifted + inside * distance, 1);
    let size = vec2f(textureDimensions(source));
    let uv = clamp(select(in.position.xy / size, vec2f(clip.x, -clip.y) / max(clip.w, .00001) * .5 + .5, valid), .5 / size, 1 - .5 / size);
    let transmitted = textureSampleLevel(source, linearSampler, uv, 0).rgb * exp(-vec3f(1, 1, .54) * distance);
    let reflected = reflectedEnvironment * 2.14;
    let panelLight = smoothstep(.5, .82, dot(reflectedEnvironment, vec3f(.2126, .7152, .0722))) * .7 * (.65 + .35 * pow(1 - facing, 1.5));
    return vec4f(max(transmitted * (1 - weight) + reflected * weight, vec3f(0)) + max(reflected * panelLight, vec3f(0)), 1);
}
@fragment fn copyScene(in: ScreenVertex) -> @location(0) vec4f {
    return textureSampleLevel(source, linearSampler, in.uv, 0);
}
@fragment fn bloomExtract(in: ScreenVertex) -> @location(0) vec4f {
    let color = max(textureSampleLevel(source, linearSampler, in.uv, 0).rgb, vec3f(0));
    let brightness = max(max(color.r, color.g), color.b);
    let soft = pow(clamp(brightness - .05, 0, .1), 2) / .2001;
    return vec4f(color * max(brightness - .1, soft) / max(brightness, .0001), 1);
}
@fragment fn bloomBlur(in: ScreenVertex) -> @location(0) vec4f {
    var color = textureSampleLevel(source, linearSampler, in.uv, 0).rgb;
    var total = 1.0;
    for (var tap = 1; tap < 14; tap++) {
        let weight = exp(-.5 * pow(f32(tap) / 4.2, 2));
        let offset = blur.xy * f32(tap);
        color += (textureSampleLevel(source, linearSampler, in.uv + offset, 0).rgb + textureSampleLevel(source, linearSampler, in.uv - offset, 0).rgb) * weight;
        total += 2 * weight;
    }
    return vec4f(color / total, 1);
}
@fragment fn composeScene(in: ScreenVertex) -> @location(0) vec4f {
    let original = textureSampleLevel(source, linearSampler, in.uv, 0).rgb;
    let light = textureSampleLevel(bloom0, linearSampler, in.uv, 0).rgb
        + textureSampleLevel(bloom1, linearSampler, in.uv, 0).rgb * .8
        + textureSampleLevel(bloom2, linearSampler, in.uv, 0).rgb * .55;
    return vec4f(toSrgb(tonemap(max(original + light * (.7 / 2.35), vec3f(0)))), 1);
}
@fragment fn antialiasScene(in: ScreenVertex) -> @location(0) vec4f {
    let texel = 1 / vec2f(textureDimensions(source));
    let center = textureLoad(source, vec2i(in.position.xy), 0).rgb;
    let nw = textureSampleLevel(source, linearSampler, in.uv + vec2f(-1, -1) * texel, 0).rgb;
    let ne = textureSampleLevel(source, linearSampler, in.uv + vec2f(1, -1) * texel, 0).rgb;
    let sw = textureSampleLevel(source, linearSampler, in.uv + vec2f(-1, 1) * texel, 0).rgb;
    let se = textureSampleLevel(source, linearSampler, in.uv + vec2f(1, 1) * texel, 0).rgb;
    let luma = vec3f(.299, .587, .114);
    let middle = dot(center, luma);
    let neighbors = vec4f(dot(nw, luma), dot(ne, luma), dot(sw, luma), dot(se, luma));
    let low = min(middle, min(min(neighbors.x, neighbors.y), min(neighbors.z, neighbors.w)));
    let high = max(middle, max(max(neighbors.x, neighbors.y), max(neighbors.z, neighbors.w)));
    let contrast = high - low;
    if (contrast < max(.03125, high * .125)) { return vec4f(center, 1); }

    let average = dot(neighbors, vec4f(.25));
    var direction = vec2f(neighbors.z + neighbors.w - neighbors.x - neighbors.y,
                          neighbors.x + neighbors.z - neighbors.y - neighbors.w);
    let reduction = max(average * .125, .0078125);
    direction = clamp(direction / (min(abs(direction.x), abs(direction.y)) + reduction), vec2f(-8), vec2f(8)) * texel;
    let narrow = (textureSampleLevel(source, linearSampler, in.uv - direction / 6, 0).rgb
                + textureSampleLevel(source, linearSampler, in.uv + direction / 6, 0).rgb) * .5;
    let wide = narrow * .5 + (textureSampleLevel(source, linearSampler, in.uv - direction * .5, 0).rgb
                           + textureSampleLevel(source, linearSampler, in.uv + direction * .5, 0).rgb) * .25;
    let brightness = dot(wide, luma);
    let filtered = select(wide, narrow, brightness < low || brightness > high);
    let subpixel = smoothstep(0, 1, abs(middle - average) / contrast);
    return vec4f(mix(filtered, (nw + ne + sw + se) * .25, subpixel * subpixel * .5), 1);
}
@fragment fn presentScene(in: ScreenVertex) -> @location(0) vec4f {
    return vec4f(textureLoad(source, vec2i(in.position.xy), 0).rgb, 1);
}
@fragment fn particleLight(in: ScreenVertex) -> @location(0) vec4f {
    var color = vec3f(0);
    for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
            color += textureSampleLevel(source, linearSampler, in.uv + (vec2f(f32(x), f32(y)) - 3.5) * .125 * blur.xy, 0).rgb;
        }
    }
    return vec4f(max(color / 64, vec3f(0)), 1);
}
struct DustVertex {
    @builtin(position) position: vec4f,
    @location(0) pointCoord: vec2f,
    @location(1) @interpolate(flat) lightUv: vec2f,
    @location(2) @interpolate(flat) sparkle: f32,
    @location(3) @interpolate(flat) softness: f32,
    @location(4) @interpolate(flat) opacity: f32,
}
fn hash11(value: f32) -> f32 { return fract(sin(value * 127.1) * 43758.5453); }
fn hashU32(input: u32) -> f32 {
    var value = input;
    value ^= value >> 16u; value *= 0x7feb352du;
    value ^= value >> 15u; value *= 0x846ca68bu;
    value ^= value >> 16u;
    return f32(value & 0x00ffffffu) / 16777216.0;
}
// prism.js wraps the dust time at this period, so every dust cycle and wave must repeat within it.
const DUST_PERIOD = 3600.0;
const TAU = 6.28318530718;
fn dustFrequency(frequency: f32) -> f32 { return round(frequency * DUST_PERIOD / TAU) * TAU / DUST_PERIOD; }
fn dustAppearance(kind: f32, size: f32) -> vec2f {
    if (kind < .82) { return vec2f(mix(1.05, 1.75, size * size), .04); }
    if (kind < .95) { return vec2f(mix(1.8, 3.8, pow(size, 1.4)), .18); }
    if (kind < .99) { return vec2f(mix(4.2, 9, pow(size, .75)), .58); }
    if (kind < .996) { return vec2f(mix(12, 28, pow(size, .8)), 1); }
    return vec2f(mix(32, 72, pow(size, .8)), 1);
}
@vertex fn dustVertex(@builtin(vertex_index) vertexId: u32, @builtin(instance_index) instance: u32) -> DustVertex {
    let time = scene.timing.x;
    let id = f32(instance) + 1;
    let cycles = round(DUST_PERIOD / mix(1, 7, hash11(id * 19.127 + 71)));
    let lifeDuration = DUST_PERIOD / cycles;
    let lifeClock = time + hash11(id * 23.417 + 83) * lifeDuration;
    let lifePhase = fract(lifeClock / lifeDuration);
    let key = (instance + 1u) ^ ((u32(floor(lifeClock / lifeDuration)) % u32(cycles)) * 0x9e3779b9u);
    let seedX = hashU32(key ^ 0xa511e9b3u);
    let seedY = hashU32(key ^ 0x63d83595u);
    let seedZ = hashU32(key ^ 0x9e3779b9u);
    let seedDepth = hashU32(key ^ 0xc2b2ae35u);
    let seedSize = hash11(id * 7.731 + 31);
    let seedClass = hash11(id * 9.173 + 37);
    let seedEnergy = hash11(id * 11.917 + 43);
    let seedShape = hash11(id * 13.531 + 47);
    let seedAngle = hash11(id * 17.273 + 59);

    var world = vec3f((vec2f(seedX, seedY) * 2 - 1) * scene.output.zw, scene.prism[1].w + (seedZ + seedDepth - 1) * .14);
    world = vec3f(world.xy * clamp((scene.camera.w - world.z) / max(scene.camera.w, .001), .08, 1), world.z);
    world += vec3f(sin(time * dustFrequency(mix(.09, .17, seedY)) + seedZ * TAU) * mix(.008, .035, seedSize),
                   sin(time * dustFrequency(mix(.07, .14, seedZ)) + seedX * TAU) * mix(.01, .04, seedY),
                   sin(time * dustFrequency(mix(.05, .1, seedX)) + seedY * TAU) * mix(.006, .025, seedZ));

    let projected = scene.viewProjection * vec4f(world, 1);
    let ndc = projected.xy / max(projected.w, .00001);
    let outputSize = max(scene.output.xy, vec2f(1));
    let lightUv = (floor(vec2f(ndc.x * .5 + .5, .5 - ndc.y * .5) * outputSize) + .5) / outputSize;
    let snapped = vec2f(lightUv.x * 2 - 1, 1 - lightUv.y * 2);
    let cornerIndex = (0xda4u >> ((vertexId % 6u) * 2u)) & 3u;
    let corner = vec2f(select(-1.0, 1.0, (cornerIndex & 1u) != 0u), select(-1.0, 1.0, (cornerIndex & 2u) != 0u));
    let appearance = dustAppearance(seedClass, seedSize);
    let aspect = mix(mix(.68, 1.32, seedShape), 1, appearance.y);
    let axisX = vec2f(cos(seedAngle * TAU), sin(seedAngle * TAU));
    let axisY = vec2f(-axisX.y, axisX.x);
    let offset = (axisX * corner.x * aspect + axisY * corner.y / max(aspect, .001)) * appearance.x / outputSize;

    let opacityBySize = min(1, pow(1.5 / max(appearance.x, 1.5), .9));
    let energy = .3 + 1.1 * pow(seedEnergy, 3);
    let twinkle = 1 + mix(.015, .06, appearance.y) * sin(time * dustFrequency(mix(.12, .28, seedShape)) + seedAngle * TAU);
    let fade = mix(.14, .24, seedShape);

    var out: DustVertex;
    out.position = vec4f((snapped + offset) * projected.w, projected.z, projected.w);
    out.pointCoord = corner;
    out.lightUv = lightUv;
    out.sparkle = opacityBySize * energy * twinkle;
    out.softness = appearance.y;
    out.opacity = smoothstep(0, fade, lifePhase) * (1 - smoothstep(1 - fade, 1, lifePhase));
    return out;
}
fn edgeSide(start: vec2f, end: vec2f, point: vec2f) -> f32 {
    let edge = end - start;
    let offset = point - start;
    return edge.x * offset.y - edge.y * offset.x;
}
@fragment fn dustFragment(in: DustVertex) -> @location(0) vec4f {
    let radiusSquared = dot(in.pointCoord, in.pointCoord);
    if (radiusSquared > 1) { discard; }
    let uv = in.position.xy / max(scene.output.xy, vec2f(1));
    let a = edgeSide(scene.prism[0].xy, scene.prism[0].zw, uv);
    let b = edgeSide(scene.prism[0].zw, scene.prism[1].xy, uv);
    let c = edgeSide(scene.prism[1].xy, scene.prism[0].xy, uv);
    if (!((a < 0 || b < 0 || c < 0) && (a > 0 || b > 0 || c > 0))) { discard; }
    let hue = max(textureSampleLevel(source, linearSampler, in.lightUv, 0).rgb, vec3f(0));
    let light = max(textureSampleLevel(bloom0, linearSampler, in.lightUv, 0).rgb, vec3f(0));
    if (all(light == vec3f(0))) { discard; }
    let illumination = pow(saturate(1 - exp(-max(max(light.r, light.g), light.b) * 82)), 5.5);
    let radial = (exp(-radiusSquared * mix(6.5, 1.8, in.softness)) + exp(-radiusSquared * 1.25) * in.softness * .2)
        * (1 - smoothstep(.62, 1, radiusSquared));
    let tint = select(light, hue, max(max(hue.r, hue.g), hue.b) > .0000001);
    let color = toSrgb(saturate(tint / max(max(max(tint.r, tint.g), tint.b), .000001)));
    let energy = toSrgb(tonemap(vec3f(illumination * radial * in.sparkle * .72))).r;
    return vec4f(color * energy * in.opacity, 0);
}
