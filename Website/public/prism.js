import { buildLight, glassMesh, lightLayout, planes, spectrum, view } from "./scene.js";

const player = document.querySelector(".player"), canvas = player.querySelector("canvas");
const motion = matchMedia("(prefers-reduced-motion: reduce)");
let device, frame = 0, resizeObserver, intersectionObserver, stopped = false;

function stop() {
    stopped = true;
    cancelAnimationFrame(frame);
    resizeObserver?.disconnect();
    intersectionObserver?.disconnect();
    player.classList.remove("ready");
    device?.destroy();
}

try {
    if (!navigator.gpu) throw new Error("WebGPU is unavailable.");
    const adapter = await navigator.gpu.requestAdapter({ powerPreference: "low-power" });
    if (!adapter) throw new Error("No WebGPU adapter.");
    device = await adapter.requestDevice();
    device.lost.then(stop);
    device.addEventListener("uncapturederror", event => { console.warn(event.error.message); stop(); });
    const context = canvas.getContext("webgpu"), format = navigator.gpu.getPreferredCanvasFormat();
    context.configure({ device, format, alphaMode: "opaque" });
    const response = await fetch("/prism.wgsl");
    if (!response.ok) throw new Error("Unable to load the prism shader.");
    const shader = device.createShaderModule({ label: "Verc prism", code: await response.text() });
    const compilation = await shader.getCompilationInfo();
    for (const message of compilation.messages) if (message.type === "error") throw new Error(`${message.lineNum}: ${message.message}`);

    const uniforms = new Float32Array(52);
    new Uint32Array(uniforms.buffer, 48 * 4).set([lightLayout.slices, lightLayout.slices, lightLayout.samples, lightLayout.internalVertices / 6]);
    planes.forEach((plane, index) => uniforms.set(plane, 28 + index * 4));
    const uniformBuffer = device.createBuffer({ size: uniforms.byteLength, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    const sceneLayout = device.createBindGroupLayout({ entries: [
        { binding: 0, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: { type: "uniform" } },
        { binding: 1, visibility: GPUShaderStage.VERTEX, buffer: { type: "uniform" } },
    ] });
    const textureLayout = device.createBindGroupLayout({ entries: [
        { binding: 0, visibility: GPUShaderStage.FRAGMENT, sampler: { type: "filtering" } },
        ...[1, 2, 3, 4].map(binding => ({ binding, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: "float" } })),
        { binding: 5, visibility: GPUShaderStage.FRAGMENT, buffer: { type: "uniform" } },
    ] });
    const layout = device.createPipelineLayout({ bindGroupLayouts: [sceneLayout, textureLayout] });
    const spectrumBuffer = device.createBuffer({ size: spectrum.byteLength, usage: GPUBufferUsage.UNIFORM, mappedAtCreation: true });
    new Float32Array(spectrumBuffer.getMappedRange()).set(spectrum);
    spectrumBuffer.unmap();
    const sceneGroup = device.createBindGroup({ layout: sceneLayout, entries: [
        { binding: 0, resource: { buffer: uniformBuffer } }, { binding: 1, resource: { buffer: spectrumBuffer } },
    ] });
    const sampler = device.createSampler({ minFilter: "linear", magFilter: "linear" });
    const dummy = device.createTexture({ size: [1, 1], format: "rgba16float", usage: GPUTextureUsage.TEXTURE_BINDING });
    const zeroBuffer = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM });
    const pipelines = {};
    const light = new Float32Array(lightLayout.vertexCount * 3), glass = glassMesh();
    const buffers = {};
    for (const [name, data, usage] of [["light", light, GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST], ["glass", glass.vertices, GPUBufferUsage.VERTEX], ["indices", glass.indices, GPUBufferUsage.INDEX]]) {
        const buffer = device.createBuffer({ size: data.byteLength, usage, mappedAtCreation: true });
        new Uint8Array(buffer.getMappedRange()).set(new Uint8Array(data.buffer));
        buffer.unmap();
        buffers[name] = buffer;
    }
    const additive = { color: { srcFactor: "one", dstFactor: "one", operation: "add" }, alpha: { srcFactor: "one", dstFactor: "one", operation: "add" } };
    const premultiplied = { color: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" }, alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" } };
    await Promise.all(["lightFragment", "glassBack", "glassFront", "copyScene", "bloomExtract", "bloomBlur", "presentScene"].map(async entryPoint => {
        const isLight = entryPoint === "lightFragment", isGlass = entryPoint.startsWith("glass");
        const vertex = { module: shader, entryPoint: isLight ? "lightVertex" : isGlass ? "glassVertex" : "screenVertex" };
        if (isLight) vertex.buffers = [{ arrayStride: 12, attributes: [{ shaderLocation: 0, offset: 0, format: "float32x3" }] }];
        if (isGlass) vertex.buffers = [{ arrayStride: 24, attributes: [
            { shaderLocation: 0, offset: 0, format: "float32x3" }, { shaderLocation: 1, offset: 12, format: "float32x3" },
        ] }];
        const target = { format: entryPoint === "presentScene" ? format : "rgba16float" };
        if (isLight) target.blend = additive;
        if (entryPoint === "glassBack") target.blend = premultiplied;
        pipelines[entryPoint] = await device.createRenderPipelineAsync({ layout, vertex,
            fragment: { module: shader, entryPoint, targets: [target] },
            primitive: { topology: "triangle-list", cullMode: isGlass ? entryPoint === "glassBack" ? "front" : "back" : "none" },
            multisample: { count: isLight || isGlass || entryPoint === "copyScene" ? 4 : 1 },
        });
    }));

    function textures(sources = [], parameterBuffer = zeroBuffer) {
        return device.createBindGroup({ layout: textureLayout, entries: [
            { binding: 0, resource: sampler },
            ...[0, 1, 2, 3].map(index => ({ binding: index + 1, resource: (sources[index] ?? dummy).createView() })),
            { binding: 5, resource: { buffer: parameterBuffer } },
        ] });
    }

    const emptyGroup = textures();
    let targets = [], blurBuffers = [], backdrop, scene, multisample, backGroup, bloomPasses = [], presentGroup;
    let visible = true, active = player.dataset.view === "prism", dirty = true, resized = true, lightDirty = true, lastFrame = 0, time = 0;
    let orbit = [0, 0], orbitTarget = [0, 0], aim = [.022, .45], aimTarget = [.022, .45], wall = [0, 0];

    function render(now) {
        frame = 0;
        if (stopped || document.hidden || !visible || !active) return;
        const delta = lastFrame ? Math.min((now - lastFrame) / 1000, .1) : 0;
        const interactive = dirty || resized || aim.some((value, axis) => value !== aimTarget[axis]) || orbit.some((value, axis) => value !== orbitTarget[axis]);
        if (!motion.matches && delta > 0 && delta < 1 / (interactive ? 60 : 30) - .001 && !dirty && !resized) {
            frame = requestAnimationFrame(render);
            return;
        }
        lastFrame = now;
        if (!motion.matches) time += delta;
        if (resized) {
            const bounds = canvas.getBoundingClientRect();
            const scale = Math.min(Math.max(devicePixelRatio, 1280 / Math.max(bounds.width, 1)), 1920 / Math.max(bounds.width, 1));
            canvas.width = Math.max(1, Math.round(bounds.width * scale));
            canvas.height = Math.max(1, Math.round(bounds.height * scale));
            const aspect = canvas.width / canvas.height;
            let worst = 0;
            for (const x of [-1, 0, 1]) {
                for (const y of [-1, 0, 1]) {
                    const camera = view(aspect, [x, y]);
                    for (const horizontal of [-1, 1]) {
                        for (const vertical of [-1, 1]) {
                            const direction = camera.forward.map((value, axis) => value + (camera.right[axis] * horizontal * aspect + camera.up[axis] * vertical) / camera.focal);
                            const distance = -camera.position[2] / direction[2];
                            worst = Math.max(worst, Math.abs(camera.position[0] + direction[0] * distance) / aspect, Math.abs(camera.position[1] + direction[1] * distance));
                        }
                    }
                }
            }
            wall = [worst * 1.02 * aspect, worst * 1.02].map(value => value * Math.min(2.5, Math.max(1, 1 / aspect)));
            lightDirty = true;
            for (const texture of targets) texture.destroy();
            for (const buffer of blurBuffers) buffer.destroy();
            targets = []; blurBuffers = []; bloomPasses = [];
            const bloom = [];
            for (const [name, divisor, samples] of [["multisample", 1, 4], ["backdrop", 1, 1], ["scene", 1, 1],
                ["extract", 2, 1], ["horizontal0", 2, 1], ["vertical0", 2, 1], ["horizontal1", 4, 1], ["vertical1", 4, 1], ["horizontal2", 8, 1], ["vertical2", 8, 1]]) {
                const texture = device.createTexture({ label: name, size: [Math.max(1, Math.floor(canvas.width / divisor)), Math.max(1, Math.floor(canvas.height / divisor))],
                    format: "rgba16float", sampleCount: samples, usage: GPUTextureUsage.RENDER_ATTACHMENT | (samples === 1 ? GPUTextureUsage.TEXTURE_BINDING : 0) });
                targets.push(texture);
            }
            [multisample, backdrop, scene] = targets;
            backGroup = textures([backdrop]);
            bloomPasses.push({ target: targets[3], pipeline: pipelines.bloomExtract, group: textures([scene]) });
            for (let level = 0; level < 3; level++) {
                const horizontal = targets[4 + level * 2], vertical = targets[5 + level * 2];
                for (const [target, source, direction] of [[horizontal, level ? targets[3 + level * 2] : targets[3], [1 / horizontal.width, 0]], [vertical, horizontal, [0, 1 / vertical.height]]]) {
                    const buffer = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM, mappedAtCreation: true });
                    new Float32Array(buffer.getMappedRange()).set([...direction, 0, 0]);
                    buffer.unmap();
                    blurBuffers.push(buffer);
                    bloomPasses.push({ target, pipeline: pipelines.bloomBlur, group: textures([source], buffer) });
                }
                bloom.push(vertical);
            }
            presentGroup = textures([scene, ...bloom]);
            resized = false;
            dirty = true;
        }
        for (const [current, target, amount, snap] of [[aim, aimTarget, .12, 1e-4], [orbit, orbitTarget, .08, 3e-3]]) {
            if (current.every((value, axis) => value === target[axis])) continue;
            const settled = current.every((value, axis) => Math.abs(target[axis] - value) < snap);
            const easing = 1 - (1 - amount) ** (delta * 60);
            for (let axis = 0; axis < 2; axis++) current[axis] = settled ? target[axis] : current[axis] + (target[axis] - current[axis]) * easing;
            if (current === aim) lightDirty = true;
            dirty = true;
        }
        if (lightDirty) {
            buildLight(aim, wall, light);
            device.queue.writeBuffer(buffers.light, 0, light);
            lightDirty = false;
        }
        if (dirty) {
            const camera = view(canvas.width / canvas.height, orbit);
            uniforms.set(camera.matrix);
            uniforms.set([...camera.position, 1.5], 16);
            uniforms.set([canvas.width, canvas.height, 0, 0], 20);
        }
        uniforms[24] = time;
        device.queue.writeBuffer(uniformBuffer, 0, uniforms);
        const encoder = device.createCommandEncoder();
        if (dirty) {
            let pass = encoder.beginRenderPass({ colorAttachments: [{ view: multisample.createView(), resolveTarget: backdrop.createView(), clearValue: [0, 0, 0, 1], loadOp: "clear", storeOp: "discard" }] });
            pass.setBindGroup(0, sceneGroup);
            pass.setBindGroup(1, emptyGroup);
            pass.setPipeline(pipelines.lightFragment);
            pass.setVertexBuffer(0, buffers.light);
            pass.draw(lightLayout.whiteVertices);
            pass.draw(lightLayout.outgoingVertices, 1, lightLayout.outgoingFirst);
            pass.setPipeline(pipelines.glassBack);
            pass.setVertexBuffer(0, buffers.glass);
            pass.setIndexBuffer(buffers.indices, "uint16");
            pass.drawIndexed(glass.indices.length);
            pass.setPipeline(pipelines.lightFragment);
            pass.setVertexBuffer(0, buffers.light);
            pass.draw(lightLayout.internalVertices, 1, lightLayout.whiteVertices);
            pass.end();
            pass = encoder.beginRenderPass({ colorAttachments: [{ view: multisample.createView(), resolveTarget: scene.createView(), clearValue: [0, 0, 0, 1], loadOp: "clear", storeOp: "discard" }] });
            pass.setBindGroup(0, sceneGroup);
            pass.setBindGroup(1, backGroup);
            pass.setPipeline(pipelines.copyScene);
            pass.draw(3);
            pass.setPipeline(pipelines.glassFront);
            pass.setVertexBuffer(0, buffers.glass);
            pass.setIndexBuffer(buffers.indices, "uint16");
            pass.drawIndexed(glass.indices.length);
            pass.end();
            for (const step of bloomPasses) {
                pass = encoder.beginRenderPass({ colorAttachments: [{ view: step.target.createView(), clearValue: [0, 0, 0, 1], loadOp: "clear", storeOp: "store" }] });
                pass.setPipeline(step.pipeline);
                pass.setBindGroup(0, sceneGroup);
                pass.setBindGroup(1, step.group);
                pass.draw(3);
                pass.end();
            }
            dirty = false;
        }
        const pass = encoder.beginRenderPass({ colorAttachments: [{ view: context.getCurrentTexture().createView(), loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 1] }] });
        pass.setPipeline(pipelines.presentScene);
        pass.setBindGroup(0, sceneGroup);
        pass.setBindGroup(1, presentGroup);
        pass.draw(3);
        pass.end();
        device.queue.submit([encoder.finish()]);
        player.classList.add("ready");
        if (!motion.matches) frame = requestAnimationFrame(render);
    }

    function schedule() {
        if (!frame && !stopped && visible && active && !document.hidden) frame = requestAnimationFrame(render);
    }
    resizeObserver = new ResizeObserver(() => { resized = true; schedule(); });
    resizeObserver.observe(canvas);
    intersectionObserver = new IntersectionObserver(entries => {
        visible = entries[0].isIntersecting;
        if (visible) { lastFrame = 0; schedule(); }
        else { cancelAnimationFrame(frame); frame = 0; }
    });
    intersectionObserver.observe(canvas);
    player.addEventListener("scenechange", () => {
        active = player.dataset.view === "prism";
        if (active) { lastFrame = 0; schedule(); }
        else { cancelAnimationFrame(frame); frame = 0; }
    });
    document.addEventListener("visibilitychange", () => {
        if (document.hidden) { cancelAnimationFrame(frame); frame = 0; }
        else { lastFrame = 0; schedule(); }
    });
    player.addEventListener("pointermove", event => {
        if (motion.matches || !active || event.pointerType !== "mouse") return;
        const bounds = canvas.getBoundingClientRect();
        const x = Math.min(1, Math.max(0, (event.clientX - bounds.left) / Math.max(bounds.width, 1)));
        const y = Math.min(1, Math.max(0, (event.clientY - bounds.top) / Math.max(bounds.height, 1)));
        aimTarget = [y, x];
        orbitTarget = [x * 2 - 1, y * 2 - 1];
        schedule();
    });
    player.addEventListener("pointerleave", () => { orbitTarget = [0, 0]; schedule(); });
    motion.addEventListener("change", () => {
        aim = [.022, .45]; aimTarget = [.022, .45]; orbit = [0, 0]; orbitTarget = [0, 0];
        dirty = lightDirty = true;
        if (motion.matches) time = 0;
        schedule();
    });
    window.addEventListener("pagehide", stop, { once: true });
    schedule();
} catch (error) {
    console.warn("Verc prism:", error.message);
    stop();
}
