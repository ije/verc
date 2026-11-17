#include <metal_stdlib>
using namespace metal;

struct Scene {
    float4x4 viewProjection;
    float4 camera;
    float4 output;
    float4 timing;
    float4 glass;
    float4 absorption;
    float4 planes[5];
    float4 prism[2];
    uint4 layout;
};

struct ScreenVertex { float4 position [[position]]; float2 uv; };

constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler mipmapClamp(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
constexpr sampler environmentSampler(coord::normalized, s_address::repeat, t_address::clamp_to_edge,
                                     filter::linear, mip_filter::linear);
constant float PI = 3.141592653589793;
constant float ENVIRONMENT_TEXEL_ANGLE = 2.0 * PI / 1024.0;

float srgbToLinear(float value) { return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4); }
float3 srgbToLinear(float3 value) { return float3(srgbToLinear(value.r), srgbToLinear(value.g), srgbToLinear(value.b)); }
float linearToSrgb(float value) { return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1.0 / 2.4) - 0.055; }
float3 linearToSrgb(float3 value) { return float3(linearToSrgb(value.r), linearToSrgb(value.g), linearToSrgb(value.b)); }
float3 tonemapAces(float3 value) {
    return saturate((value * (2.51 * value + 0.03)) / (value * (2.43 * value + 0.59) + 0.14));
}

vertex ScreenVertex screenVertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return { float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1), uv };
}

float studioPanel(float3 direction, float3 panel, float2 size, float feather) {
    float3 forward = normalize(panel);
    float3 helper = abs(forward.y) > 0.92 ? float3(0, 0, 1) : float3(0, 1, 0);
    float3 right = normalize(cross(helper, forward));
    float3 up = cross(forward, right);
    float facing = dot(direction, forward);
    if (facing <= 0.01) return 0;
    float2 local = abs(float2(dot(direction, right), dot(direction, up)) / facing);
    float2 edge = 1.0 - smoothstep(size, size + feather, local);
    return edge.x * edge.y;
}

float3 studio(float3 direction) {
    direction = normalize(direction);
    float floorBlend = 1.0 - smoothstep(-0.22, -0.02, direction.y);
    float3 room = mix(float3(0.00025, 0.0003, 0.0004), float3(0.006, 0.007, 0.009), floorBlend);
    float backWall = (1.0 - smoothstep(-0.08, 0.08, direction.z)) * smoothstep(-0.28, -0.08, direction.y);
    room = mix(room, float3(0.00002), backWall);
    float horizon = exp(-abs(direction.y + 0.1) * 22.0) * 0.0012;
    float3 color = room + float3(horizon, horizon * 0.96, horizon * 0.9);
    color += float3(0.82, 0.84, 0.88) * studioPanel(direction, float3(-0.82, 0.08, 0.57), float2(1.35, 1.1), 0.22) * 0.011;
    color += float3(1, 0.97, 0.91) * studioPanel(direction, float3(0, -0.707, 0.707), float2(0.38, 0.62), 0.18) * 0.22;
    color += float3(0.76, 0.88, 1) * studioPanel(direction, float3(0.612, 0.354, 0.707), float2(0.5, 0.16), 0.035) * 20.0;
    float3 mapped = color / (1.0 + color);
    return srgbToLinear(pow(max(mapped, 0.0), float3(1.0 / 2.2)));
}

fragment float4 bakeEnvironment(ScreenVertex in [[stage_in]]) {
    float phi = (in.uv.x - 0.5) * 2.0 * PI;
    float theta = in.uv.y * PI;
    return float4(studio(float3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))), 1);
}

fragment float4 blurEnvironment(ScreenVertex in [[stage_in]], texture2d<float> source [[texture(0)]],
                                constant float4 &blur [[buffer(0)]]) {
    float scale = mix(1.0, 1.0 / max(sin(in.uv.y * PI), 0.15), blur.w);
    float2 step = blur.xy * blur.z * scale;
    const float offsets[3] = { 0.0, 1.3846153846, 3.2307692308 };
    const float weights[3] = { 0.2270270270, 0.3162162162, 0.0702702703 };
    float4 sum = source.sample(environmentSampler, in.uv, level(0)) * weights[0];
    for (int index = 1; index < 3; ++index) {
        sum += source.sample(environmentSampler, in.uv + step * offsets[index], level(0)) * weights[index];
        sum += source.sample(environmentSampler, in.uv - step * offsets[index], level(0)) * weights[index];
    }
    return sum;
}

float environmentLod(float3 dx, float3 dy) {
    return max(log2(max(length(dx), length(dy)) / ENVIRONMENT_TEXEL_ANGLE), 0.0);
}

float3 sampleEnvironment(texture2d<float> environment, float3 direction, float lod, constant Scene &s) {
    float3 d = normalize(direction);
    float2 uv = float2(atan2(d.z, d.x) / (2.0 * PI) + 0.5, acos(clamp(d.y, -1.0, 1.0)) / PI);
    lod = clamp(lod, 0.0, float(environment.get_num_mip_levels() - 1));
    float2 size = max(float2(environment.get_width(), environment.get_height()) / exp2(lod), float2(2));
    float2 texel = uv * size - 0.5;
    float2 f = fract(texel);
    uv = (floor(texel) + f * f * (3.0 - 2.0 * f) + 0.5) / size;
    return environment.sample(environmentSampler, uv, level(lod)).rgb * s.glass.w;
}

// Centroid sampling: the spectral cells are slivers, and a pixel centre outside
// one would extrapolate its colour under multisampling.
struct LightVertex {
    float4 position [[position]];
    float3 color [[centroid_perspective]];
    float profile [[centroid_perspective]];
    float intensity [[centroid_perspective]];
    float travel [[centroid_perspective]];
    float revealProfile [[centroid_perspective]];
};

float beamBoundary(uint boundary, uint slices) { return -1.0 + 2.0 * float(boundary) / float(max(slices, 1u)); }

vertex LightVertex lightVertex(uint id [[vertex_id]], const device packed_float3 *mesh [[buffer(0)]],
                               constant Scene &s [[buffer(1)]], constant float4 *spectrum [[buffer(2)]]) {
    float3 data = mesh[id];
    uint quad = id / 6, corner = id % 6;
    uint upper = (22u >> corner) & 1u;
    uint slices = s.layout.y;
    float profile = 0, travel = 0, revealProfile;
    uint spectral = 0;
    bool white = quad < s.layout.x;
    if (white) {
        profile = beamBoundary(quad + upper, slices);
        revealProfile = profile;
    } else if (quad - s.layout.x < s.layout.w) {
        uint spectralQuad = quad - s.layout.x;
        spectral = spectralQuad / (slices * 4u);
        profile = beamBoundary((spectralQuad % (slices * 4u)) / 4u + upper, slices);
        revealProfile = profile;
    } else {
        uint outgoing = quad - s.layout.x - s.layout.w;
        uint slice = outgoing % slices;
        spectral = outgoing / slices + upper;
        travel = float((52u >> corner) & 1u);
        revealProfile = 0.5 * (beamBoundary(slice, slices) + beamBoundary(slice + 1, slices));
    }
    float3 color = float3(1);
    if (!white && data.z >= 0) {
        uint samples = s.layout.z;
        float coordinate = float(min(spectral, samples - 1)) * 127.0 / float(max(samples - 1, 1u));
        uint lower = min(uint(floor(coordinate)), 126u);
        color = mix(spectrum[lower], spectrum[lower + 1], coordinate - float(lower)).rgb;
    }
    return { s.viewProjection * float4(data.xy, s.prism[1].w, 1), color, profile, max(data.z, 0.0), travel, revealProfile };
}

float lightRadial(float profile) {
    float radius = abs(profile);
    return exp(-16.0 * radius * radius) * (1.0 - smoothstep(0.55, 1.0, radius));
}

float beamWidthReveal(float profile, float progress) {
    float reveal = clamp(progress, 0.0, 1.0);
    float antialias = max(fwidth(profile) * 1.5, 0.04);
    if (reveal <= 0) return 0;
    if (reveal >= 1) return 1;
    return 1.0 - smoothstep(max(reveal - antialias, 0.0), min(reveal + antialias, 1.0), abs(profile));
}

fragment float4 lightFragment(LightVertex in [[stage_in]], constant Scene &s [[buffer(1)]]) {
    float falloff = 1.0 / pow(1.0 + 3.8 * max(in.travel, 0.0), 3.7);
    return float4(in.color * in.intensity * lightRadial(in.profile) * beamWidthReveal(in.revealProfile, s.timing.z) * falloff, 0);
}

struct MeshVertex { packed_float3 position; packed_float3 normal; };
// Shaded per MSAA sample: across a sub-pixel bevel the normal sweeps through
// the key light, which one sample per pixel turns into a dotted rim.
struct GlassVertex {
    float4 position [[position]];
    float3 worldPosition [[sample_perspective]];
    float3 normal [[sample_perspective]];
};

vertex GlassVertex glassVertex(uint id [[vertex_id]], const device MeshVertex *mesh [[buffer(0)]], constant Scene &s [[buffer(1)]]) {
    float3 position = mesh[id].position;
    return { s.viewProjection * float4(position, 1), position, mesh[id].normal };
}

float fresnel(float f0, float facing) {
    float grazing = 1.0 - saturate(facing);
    float squared = grazing * grazing;
    return f0 + (1.0 - f0) * squared * squared * grazing;
}

float exitFresnel(float f0, float facing, float ior) {
    return fresnel(f0, sqrt(max(1.0 - ior * ior * (1.0 - facing * facing), 0.0)));
}

struct Ray { float3 value; float3 dx; float3 dy; };

Ray normalizedRay(float3 value, float3 dx, float3 dy) {
    float magnitude = length(value);
    float3 unit = value / magnitude;
    return { unit, (dx - unit * dot(unit, dx)) / magnitude, (dy - unit * dot(unit, dy)) / magnitude };
}

Ray reflectRay(Ray ray, Ray normal) {
    float facing = dot(ray.value, normal.value);
    float facingDx = dot(ray.dx, normal.value) + dot(ray.value, normal.dx);
    float facingDy = dot(ray.dy, normal.value) + dot(ray.value, normal.dy);
    return normalizedRay(reflect(ray.value, normal.value),
                         ray.dx - 2.0 * (facingDx * normal.value + facing * normal.dx),
                         ray.dy - 2.0 * (facingDy * normal.value + facing * normal.dy));
}

Ray refractRay(Ray ray, Ray normal, float eta) {
    float facing = dot(ray.value, normal.value);
    float k = 1.0 - eta * eta * (1.0 - facing * facing);
    if (k < 0.0) return { float3(0), float3(0), float3(0) };
    float root = sqrt(k);
    float scale = eta * facing + root;
    float slope = eta + eta * eta * facing / max(root, 0.00001);
    float facingDx = dot(ray.dx, normal.value) + dot(ray.value, normal.dx);
    float facingDy = dot(ray.dy, normal.value) + dot(ray.value, normal.dy);
    return normalizedRay(eta * ray.value - scale * normal.value,
                         eta * ray.dx - slope * facingDx * normal.value - scale * normal.dx,
                         eta * ray.dy - slope * facingDy * normal.value - scale * normal.dy);
}

constant uint NO_PLANE = 5;

float4 nextSurface(float3 origin, float3 direction, uint departed, constant Scene &s, thread uint &plane) {
    float nearest = 100000;
    float3 normal = s.planes[3].xyz;
    const uint order[5] = { 3, 4, 0, 1, 2 };
    for (uint index = 0; index < 5; ++index) {
        uint candidate = order[index];
        if (candidate == departed) continue;
        float denominator = dot(s.planes[candidate].xyz, direction);
        if (denominator <= 0.00001) continue;
        float distance = (s.planes[candidate].w - dot(s.planes[candidate].xyz, origin)) / denominator;
        if (distance >= 0.0 && distance < nearest) {
            nearest = distance;
            normal = s.planes[candidate].xyz;
            plane = candidate;
        }
    }
    return float4(normal, nearest);
}

struct Exit { float3 position; Ray direction; Ray incident; Ray inwardNormal; bool escaped; uint plane; };

Exit traceExit(float3 position, Ray direction, Ray inwardNormal, uint plane, constant Scene &s) {
    for (uint bounce = 0; bounce <= 3; ++bounce) {
        Ray transmitted = refractRay(direction, inwardNormal, s.glass.x);
        if (length(transmitted.value) > 0.00001) return { position, transmitted, direction, inwardNormal, true, plane };
        direction = reflectRay(direction, inwardNormal);
        uint next = plane;
        float4 hit = nextSurface(position, direction.value, plane, s, next);
        if (hit.w >= 10.0) break;
        position += direction.value * hit.w;
        plane = next;
        inwardNormal = { -hit.xyz, float3(0), float3(0) };
    }
    return { position, direction, direction, inwardNormal, false, plane };
}

float4 backSurface(float3 position, float3 normal, Ray incident, Ray inward, texture2d<float> environment, constant Scene &s) {
    incident.value = -normalize(s.camera.xyz - position);
    inward.value = -normalize(normal);
    Exit exit = traceExit(position, incident, inward, NO_PLANE, s);
    Ray reflected = reflectRay(exit.incident, exit.inwardNormal);
    uint plane = exit.plane;
    float4 hit = nextSurface(exit.position, reflected.value, exit.plane, s, plane);
    Exit reflectedExit = hit.w >= 10.0
        ? Exit { exit.position, reflected, reflected, exit.inwardNormal, false, exit.plane }
        : traceExit(exit.position + reflected.value * hit.w, reflected, { -hit.xyz, float3(0), float3(0) }, plane, s);
    float reflectedFacing = saturate(-dot(reflectedExit.incident.value, reflectedExit.inwardNormal.value));
    float transmission = reflectedExit.escaped ? 1.0 - exitFresnel(s.glass.y, reflectedFacing, s.glass.x) : 0.0;
    float3 environmentColor = sampleEnvironment(environment, reflectedExit.direction.value,
                                                environmentLod(reflectedExit.direction.dx, reflectedExit.direction.dy), s)
        * s.glass.z * transmission;
    float facing = saturate(-dot(exit.incident.value, exit.inwardNormal.value));
    float weight = exit.escaped ? exitFresnel(s.glass.y, facing, s.glass.x) : 1.0;
    return float4(environmentColor * weight, weight);
}

// The back bevel turns about 90 degrees within a few pixels, and total internal reflection switches on and
// off inside it. Four samples per pixel still leave those sub-pixel lines dotted, so shade 8 points per sample there.
fragment float4 glassBack(GlassVertex in [[stage_in]], constant Scene &s [[buffer(1)]],
                          texture2d<float> environment [[texture(0)]]) {
    float3 incident = -normalize(s.camera.xyz - in.worldPosition);
    float3 inward = -normalize(in.normal);
    Ray incidentRay = { incident, dfdx(incident), dfdy(incident) }, inwardRay = { inward, dfdx(inward), dfdy(inward) };
    float3 positionDx = dfdx(in.worldPosition), positionDy = dfdy(in.worldPosition);
    float3 normalDx = dfdx(in.normal), normalDy = dfdy(in.normal);
    if (length(inwardRay.dx) + length(inwardRay.dy) < 0.05) return backSurface(in.worldPosition, in.normal, incidentRay, inwardRay, environment, s);
    const float2 offsets[8] = { float2(0.03125, -0.09375), float2(-0.03125, 0.09375), float2(0.15625, 0.03125), float2(-0.09375, -0.15625),
                                float2(-0.15625, 0.15625), float2(-0.21875, -0.03125), float2(0.09375, 0.21875), float2(0.21875, -0.21875) };
    float4 sum = 0;
    for (uint index = 0; index < 8; ++index) {
        float2 offset = offsets[index];
        sum += backSurface(in.worldPosition + positionDx * offset.x + positionDy * offset.y,
                           in.normal + normalDx * offset.x + normalDy * offset.y, incidentRay, inwardRay, environment, s);
    }
    return sum * 0.125;
}

fragment float4 glassFront(GlassVertex in [[stage_in]], constant Scene &s [[buffer(1)]],
                           texture2d<float> backdrop [[texture(0)]], texture2d<float> environment [[texture(1)]]) {
    float3 normal = normalize(in.normal);
    float3 view = normalize(s.camera.xyz - in.worldPosition);
    float facing = saturate(dot(view, normal));
    float3 reflection = reflect(-view, normal);
    float3 reflectedEnvironment = sampleEnvironment(environment, reflection, environmentLod(dfdx(reflection), dfdy(reflection)), s);
    float weight = fresnel(s.glass.y, facing);
    float3 inside = normalize(refract(-view, normal, 1.0 / s.glass.x));
    float3 shifted = in.worldPosition + inside * 0.0002;
    float distance = 100000;
    const uint order[5] = { 3, 4, 0, 1, 2 };
    for (uint index = 0; index < 5; ++index) {
        float4 plane = s.planes[order[index]];
        float denominator = dot(plane.xyz, inside);
        if (denominator <= 0.00001) continue;
        float candidate = (plane.w - dot(plane.xyz, shifted)) / denominator;
        if (candidate > 0.0001 && candidate < distance) distance = candidate;
    }
    bool valid = distance < 10.0;
    distance = valid ? distance : 0;
    float2 size = float2(backdrop.get_width(), backdrop.get_height());
    float4 clip = s.viewProjection * float4(shifted + inside * distance, 1);
    float2 uv = valid ? float2(clip.x, -clip.y) / max(clip.w, 0.00001) * 0.5 + 0.5 : in.position.xy / size;

    float lod = log2(max(max(length(dfdx(uv * size)), length(dfdy(uv * size))), 1.0));
    uv = clamp(uv, 0.5 / size, 1.0 - 0.5 / size);
    float3 transmitted = valid ? backdrop.sample(mipmapClamp, uv, level(lod)).rgb * exp(-s.absorption.rgb * distance) : float3(0);
    float3 reflected = reflectedEnvironment * s.glass.z;
    float panel = smoothstep(0.5, 0.82, dot(reflectedEnvironment, float3(0.2126, 0.7152, 0.0722)))
        * clamp(s.glass.z * 0.4, 0.0, 0.7) * (0.65 + 0.35 * pow(1.0 - facing, 1.5));
    float3 color = max(transmitted * (1.0 - weight) + reflected * weight, 0.0) + max(reflected * panel, 0.0);
    return float4(color, 1);
}

fragment float4 copyLinear(ScreenVertex in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    return source.read(uint2(in.position.xy));
}

fragment float4 bloomExtract(ScreenVertex in [[stage_in]], texture2d<float> source [[texture(0)]],
                             constant float &threshold [[buffer(0)]]) {
    float3 color = max(source.sample(linearClamp, in.uv).rgb, 0.0);
    float brightness = max(max(color.r, color.g), color.b);
    float knee = max(threshold * 0.5, 0.0001);
    float soft = clamp(brightness - threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 0.0001);
    return float4(color * max(brightness - threshold, soft) / max(brightness, 0.0001), 1);
}

struct Blur { float2 direction; float2 texel; float4 coefficients[6]; uint taps; };

fragment float4 bloomBlur(ScreenVertex in [[stage_in]], texture2d<float> source [[texture(0)]], constant Blur &blur [[buffer(0)]]) {
    float3 color = source.sample(linearClamp, in.uv).rgb * blur.coefficients[0].x;
    for (uint tap = 1; tap < min(blur.taps, 24u); ++tap) {
        float2 offset = blur.direction * blur.texel * float(tap);
        float weight = blur.coefficients[tap / 4][tap % 4];
        color += (source.sample(linearClamp, in.uv + offset).rgb + source.sample(linearClamp, in.uv - offset).rgb) * weight;
    }
    return float4(max(color, 0.0), 1);
}

fragment float4 particleLight(ScreenVertex in [[stage_in]], texture2d<float> source [[texture(0)]],
                              constant float4 &params [[buffer(0)]]) {
    float3 color = float3(0);
    for (uint y = 0; y < 8; ++y) {
        for (uint x = 0; x < 8; ++x) {
            float2 offset = (float2(x, y) - 3.5) * 0.125 * params.zw * params.xy;
            color += source.sample(linearClamp, in.uv + offset).rgb;
        }
    }
    return float4(max(color / 64.0, 0.0), 1);
}

fragment float4 bloomComposite(ScreenVertex in [[stage_in]], texture2d<float> level0 [[texture(0)]],
                               texture2d<float> level1 [[texture(1)]], texture2d<float> level2 [[texture(2)]]) {
    float3 color = level0.sample(linearClamp, in.uv).rgb + level1.sample(linearClamp, in.uv).rgb * 0.8
        + level2.sample(linearClamp, in.uv).rgb * 0.55;
    return float4(max(color / 2.35, 0.0), 1);
}

fragment float4 presentScene(ScreenVertex in [[stage_in]], texture2d<float> scene [[texture(0)]],
                             texture2d<float> bloom [[texture(1)]]) {
    float3 color = scene.read(uint2(in.position.xy)).rgb + bloom.sample(linearClamp, in.uv).rgb * 0.7;
    return float4(linearToSrgb(tonemapAces(max(color, 0.0))), 1);
}

fragment float4 antialiasScene(ScreenVertex in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    float2 texel = 1.0 / float2(source.get_width(), source.get_height());
    float3 center = source.read(uint2(in.position.xy)).rgb;
    float3 nw = source.sample(linearClamp, in.uv + float2(-1, -1) * texel, level(0)).rgb;
    float3 ne = source.sample(linearClamp, in.uv + float2(1, -1) * texel, level(0)).rgb;
    float3 sw = source.sample(linearClamp, in.uv + float2(-1, 1) * texel, level(0)).rgb;
    float3 se = source.sample(linearClamp, in.uv + float2(1, 1) * texel, level(0)).rgb;
    const float3 luma = float3(0.299, 0.587, 0.114);
    float middle = dot(center, luma);
    float4 neighbors = float4(dot(nw, luma), dot(ne, luma), dot(sw, luma), dot(se, luma));
    float low = min(middle, min(min(neighbors.x, neighbors.y), min(neighbors.z, neighbors.w)));
    float high = max(middle, max(max(neighbors.x, neighbors.y), max(neighbors.z, neighbors.w)));
    float contrast = high - low;
    if (contrast < max(0.03125, high * 0.125)) return float4(center, 1);

    float average = dot(neighbors, float4(0.25));
    float2 direction = float2(neighbors.z + neighbors.w - neighbors.x - neighbors.y,
                              neighbors.x + neighbors.z - neighbors.y - neighbors.w);
    float reduction = max(average * 0.125, 0.0078125);
    direction = clamp(direction / (min(abs(direction.x), abs(direction.y)) + reduction), -8.0, 8.0) * texel;
    float3 narrow = (source.sample(linearClamp, in.uv - direction / 6.0, level(0)).rgb
                  + source.sample(linearClamp, in.uv + direction / 6.0, level(0)).rgb) * 0.5;
    float3 wide = narrow * 0.5 + (source.sample(linearClamp, in.uv - direction * 0.5, level(0)).rgb
                               + source.sample(linearClamp, in.uv + direction * 0.5, level(0)).rgb) * 0.25;
    float brightness = dot(wide, luma);
    float3 filtered = brightness < low || brightness > high ? narrow : wide;
    float subpixel = smoothstep(0.0, 1.0, abs(middle - average) / contrast);
    return float4(mix(filtered, (nw + ne + sw + se) * 0.25, subpixel * subpixel * 0.5), 1);
}

fragment float4 revealScene(ScreenVertex in [[stage_in]], texture2d<float> presented [[texture(0)]],
                            constant Scene &s [[buffer(1)]]) {
    return float4(presented.read(uint2(in.position.xy)).rgb * saturate(s.timing.y), 1);
}

struct DustVertex {
    float4 position [[position]];
    float2 pointCoord;
    float2 lightUv [[flat]];
    float sparkle [[flat]];
    float softness [[flat]];
    float2 prismA [[flat]];
    float2 prismB [[flat]];
    float2 prismC [[flat]];
    float opacity [[flat]];
};

float hash11(float value) { return fract(sin(value * 127.1) * 43758.5453); }

float hashU32(uint value) {
    value ^= value >> 16; value *= 0x7feb352du;
    value ^= value >> 15; value *= 0x846ca68bu;
    value ^= value >> 16;
    return float(value & 0x00ffffffu) / 16777216.0;
}

float2 projectUv(float3 point, constant Scene &s) {
    float4 clip = s.viewProjection * float4(point, 1);
    float2 ndc = clip.xy / max(clip.w, 0.00001);
    return float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
}

float2 dustAppearance(float kind, float size) {
    if (kind < 0.82) return float2(mix(1.05, 1.75, size * size), 0.04);
    if (kind < 0.95) return float2(mix(1.8, 3.8, pow(size, 1.4)), 0.18);
    if (kind < 0.99) return float2(mix(4.2, 9.0, pow(size, 0.75)), 0.58);
    if (kind < 0.996) return float2(mix(12.0, 28.0, pow(size, 0.8)), 1.0);
    return float2(mix(32.0, 72.0, pow(size, 0.8)), 1.0);
}

vertex DustVertex dustVertex(uint vertexId [[vertex_id]], uint instance [[instance_id]], constant Scene &s [[buffer(1)]]) {
    const float TAU = 6.28318530718;
    float time = s.timing.x;
    float id = float(instance) + 1.0;
    float lifeDuration = mix(1.0, 7.0, hash11(id * 19.127 + 71.0));
    float lifeClock = time + hash11(id * 23.417 + 83.0) * lifeDuration;
    float lifePhase = fract(lifeClock / lifeDuration);
    uint key = (instance + 1u) ^ (uint(floor(lifeClock / lifeDuration)) * 0x9e3779b9u);
    float seedX = hashU32(key ^ 0xa511e9b3u), seedY = hashU32(key ^ 0x63d83595u);
    float seedZ = hashU32(key ^ 0x9e3779b9u), seedDepth = hashU32(key ^ 0xc2b2ae35u);
    float seedSize = hash11(id * 7.731 + 31.0), seedClass = hash11(id * 9.173 + 37.0);
    float seedEnergy = hash11(id * 11.917 + 43.0), seedShape = hash11(id * 13.531 + 47.0);
    float seedAngle = hash11(id * 17.273 + 59.0);

    float lightZ = s.prism[1].w;
    float3 world = float3((float2(seedX, seedY) * 2.0 - 1.0) * s.output.zw, lightZ + (seedZ + seedDepth - 1.0) * 0.14);
    world.xy *= clamp((s.camera.w - world.z) / max(s.camera.w, 0.001), 0.08, 1.0);
    world += float3(sin(time * mix(0.09, 0.17, seedY) + seedZ * TAU) * mix(0.008, 0.035, seedSize),
                    sin(time * mix(0.07, 0.14, seedZ) + seedX * TAU) * mix(0.01, 0.04, seedY),
                    sin(time * mix(0.05, 0.1, seedX) + seedY * TAU) * mix(0.006, 0.025, seedZ));

    float4 projected = s.viewProjection * float4(world, 1);
    float2 ndc = projected.xy / max(projected.w, 0.00001);
    float2 outputSize = max(s.output.xy, float2(1));

    float2 lightUv = (floor(float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5) * outputSize) + 0.5) / outputSize;
    float2 snapped = float2(lightUv.x * 2.0 - 1.0, 1.0 - lightUv.y * 2.0);
    uint cornerIndex = (vertexId % 6 == 0) ? 0 : (vertexId % 6 == 1 || vertexId % 6 == 4) ? 1 : (vertexId % 6 == 5) ? 3 : 2;
    float2 corner = float2((cornerIndex & 1) ? 1.0 : -1.0, (cornerIndex & 2) ? 1.0 : -1.0);
    float2 appearance = dustAppearance(seedClass, seedSize);
    float aspect = mix(mix(0.68, 1.32, seedShape), 1.0, appearance.y);
    float angle = seedAngle * TAU;
    float2 axisX = float2(cos(angle), sin(angle));
    float2 axisY = float2(-axisX.y, axisX.x);
    float2 shaped = axisX * corner.x * aspect + axisY * corner.y / max(aspect, 0.001);
    float2 offset = shaped * appearance.x / outputSize;

    float opacityBySize = min(1.0, pow(1.5 / max(appearance.x, 1.5), 0.9));
    float energy = 0.3 + 1.1 * pow(seedEnergy, 3.0);
    float twinkle = 1.0 + mix(0.015, 0.06, appearance.y) * sin(time * mix(0.12, 0.28, seedShape) + seedAngle * TAU);
    float fade = mix(0.14, 0.24, seedShape);
    float lifecycle = smoothstep(0.0, fade, lifePhase) * (1.0 - smoothstep(1.0 - fade, 1.0, lifePhase));

    DustVertex out;
    out.position = float4((snapped + offset) * projected.w, projected.z, projected.w);
    out.pointCoord = corner;
    out.lightUv = lightUv;
    out.sparkle = opacityBySize * energy * twinkle;
    out.softness = appearance.y;
    out.prismA = projectUv(float3(s.prism[0].xy, s.prism[1].z), s);
    out.prismB = projectUv(float3(s.prism[0].zw, s.prism[1].z), s);
    out.prismC = projectUv(float3(s.prism[1].xy, s.prism[1].z), s);
    out.opacity = lifecycle;
    return out;
}

float edgeSide(float2 start, float2 end, float2 point) {
    float2 edge = end - start, offset = point - start;
    return edge.x * offset.y - edge.y * offset.x;
}

fragment float4 dustFragment(DustVertex in [[stage_in]], constant Scene &s [[buffer(1)]],
                             texture2d<float> colorLight [[texture(0)]], texture2d<float> particleLight [[texture(1)]]) {
    float radiusSquared = dot(in.pointCoord, in.pointCoord);
    if (radiusSquared > 1.0 || s.timing.y <= 0) discard_fragment();
    float2 uv = in.position.xy / max(s.output.xy, float2(1));
    float a = edgeSide(in.prismA, in.prismB, uv), b = edgeSide(in.prismB, in.prismC, uv), c = edgeSide(in.prismC, in.prismA, uv);
    if (!((a < 0 || b < 0 || c < 0) && (a > 0 || b > 0 || c > 0))) discard_fragment();

    float3 hue = max(colorLight.sample(linearClamp, in.lightUv).rgb, 0.0);
    float3 light = max(particleLight.sample(linearClamp, in.lightUv).rgb, 0.0);
    if (all(light == 0.0)) discard_fragment();
    float illumination = pow(saturate(1.0 - exp(-max(max(light.r, light.g), light.b) * 82.0)), 5.5);
    float radial = (exp(-radiusSquared * mix(6.5, 1.8, in.softness)) + exp(-radiusSquared * 1.25) * in.softness * 0.2)
        * (1.0 - smoothstep(0.62, 1.0, radiusSquared));
    float3 source = max(max(hue.r, hue.g), hue.b) > 0.0000001 ? hue : light;
    float3 color = linearToSrgb(saturate(source / max(max(max(source.r, source.g), source.b), 0.000001)));
    float energy = linearToSrgb(tonemapAces(float3(illumination * radial * in.sparkle * 0.72))).r;
    return float4(color * energy * in.opacity * saturate(s.timing.y), 0);
}
