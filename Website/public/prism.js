import {
  buildLight,
  glassMesh,
  lightLayout,
  planes,
  spectrum,
  triangle,
  view,
} from "./scene.js";

const player = document.querySelector(".player"),
  canvas = player.querySelector("canvas");
const motion = matchMedia("(prefers-reduced-motion: reduce)");
const restingAim = [0.022, 0.45];
const maxRenderPixels = 2560 * 1440;
let device,
  frame = 0,
  resizeObserver,
  intersectionObserver,
  resolution,
  stopped = false;

function stop() {
  stopped = true;
  cancelAnimationFrame(frame);
  resizeObserver?.disconnect();
  intersectionObserver?.disconnect();
  if (resolution) resolution.onchange = null;
  player.classList.remove("ready");
  device?.destroy();
}

try {
  if (!navigator.gpu) throw new Error("WebGPU is unavailable.");
  const adapter = await navigator.gpu.requestAdapter({
    powerPreference: "low-power",
  });
  if (!adapter) throw new Error("No WebGPU adapter.");
  device = await adapter.requestDevice();
  device.lost.then(stop);
  device.addEventListener("uncapturederror", (event) => {
    console.warn(event.error.message);
    stop();
  });
  const context = canvas.getContext("webgpu"),
    format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format, alphaMode: "opaque" });
  const response = await fetch("/prism.wgsl");
  if (!response.ok) throw new Error("Unable to load the prism shader.");
  const shader = device.createShaderModule({
    label: "Verc prism",
    code: await response.text(),
  });
  const compilation = await shader.getCompilationInfo();
  for (const message of compilation.messages)
    if (message.type === "error")
      throw new Error(`${message.lineNum}: ${message.message}`);

  const uniforms = new Float32Array(60);
  uniforms[55] = (planes[3][3] - planes[4][3]) / 2;
  new Uint32Array(uniforms.buffer, 56 * 4).set([
    lightLayout.slices,
    lightLayout.slices,
    lightLayout.samples,
    lightLayout.internalVertices / 6,
  ]);
  planes.forEach((plane, index) => uniforms.set(plane, 28 + index * 4));
  const uniformBuffer = device.createBuffer({
    size: uniforms.byteLength,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });
  const sceneLayout = device.createBindGroupLayout({
    entries: [
      {
        binding: 0,
        visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
        buffer: { type: "uniform" },
      },
      {
        binding: 1,
        visibility: GPUShaderStage.VERTEX,
        buffer: { type: "uniform" },
      },
    ],
  });
  const textureLayout = device.createBindGroupLayout({
    entries: [
      {
        binding: 0,
        visibility: GPUShaderStage.FRAGMENT,
        sampler: { type: "filtering" },
      },
      ...[1, 2, 3, 4].map((binding) => ({
        binding,
        visibility: GPUShaderStage.FRAGMENT,
        texture: { sampleType: "float" },
      })),
      {
        binding: 5,
        visibility: GPUShaderStage.FRAGMENT,
        buffer: { type: "uniform" },
      },
    ],
  });
  const layout = device.createPipelineLayout({
    bindGroupLayouts: [sceneLayout, textureLayout],
  });
  const spectrumBuffer = device.createBuffer({
    size: spectrum.byteLength,
    usage: GPUBufferUsage.UNIFORM,
    mappedAtCreation: true,
  });
  new Float32Array(spectrumBuffer.getMappedRange()).set(spectrum);
  spectrumBuffer.unmap();
  const sceneGroup = device.createBindGroup({
    layout: sceneLayout,
    entries: [
      { binding: 0, resource: { buffer: uniformBuffer } },
      { binding: 1, resource: { buffer: spectrumBuffer } },
    ],
  });
  const sampler = device.createSampler({
    minFilter: "linear",
    magFilter: "linear",
  });
  const dummy = device.createTexture({
    size: [1, 1],
    format: "rgba16float",
    usage: GPUTextureUsage.TEXTURE_BINDING,
  });
  const zeroBuffer = device.createBuffer({
    size: 16,
    usage: GPUBufferUsage.UNIFORM,
  });
  const pipelines = {};
  const light = new Float32Array(lightLayout.vertexCount * 3),
    glass = glassMesh();
  const buffers = {};
  for (const [name, data, usage] of [
    ["light", light, GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST],
    ["glass", glass.vertices, GPUBufferUsage.VERTEX],
    ["indices", glass.indices, GPUBufferUsage.INDEX],
  ]) {
    const buffer = device.createBuffer({
      size: data.byteLength,
      usage,
      mappedAtCreation: true,
    });
    new Uint8Array(buffer.getMappedRange()).set(new Uint8Array(data.buffer));
    buffer.unmap();
    buffers[name] = buffer;
  }
  const additive = {
    color: { srcFactor: "one", dstFactor: "one", operation: "add" },
    alpha: { srcFactor: "one", dstFactor: "one", operation: "add" },
  };
  const premultiplied = {
    color: {
      srcFactor: "one",
      dstFactor: "one-minus-src-alpha",
      operation: "add",
    },
    alpha: {
      srcFactor: "one",
      dstFactor: "one-minus-src-alpha",
      operation: "add",
    },
  };
  await Promise.all(
    [
      "lightFragment",
      "glassBack",
      "glassFront",
      "copyScene",
      "bloomExtract",
      "bloomBlur",
      "composeScene",
      "antialiasScene",
      "presentScene",
      "particleLight",
      "dustFragment",
    ].map(async (entryPoint) => {
      const isLight = entryPoint === "lightFragment",
        isGlass = entryPoint.startsWith("glass"),
        isDust = entryPoint === "dustFragment";
      const vertex = {
        module: shader,
        entryPoint: isLight
          ? "lightVertex"
          : isGlass
            ? "glassVertex"
            : isDust
              ? "dustVertex"
              : "screenVertex",
      };
      if (isLight)
        vertex.buffers = [
          {
            arrayStride: 12,
            attributes: [{ shaderLocation: 0, offset: 0, format: "float32x3" }],
          },
        ];
      if (isGlass)
        vertex.buffers = [
          {
            arrayStride: 24,
            attributes: [
              { shaderLocation: 0, offset: 0, format: "float32x3" },
              { shaderLocation: 1, offset: 12, format: "float32x3" },
            ],
          },
        ];
      const target = {
        format:
          entryPoint === "presentScene" || isDust ? format : "rgba16float",
      };
      if (isLight || isDust) target.blend = additive;
      if (entryPoint === "glassBack") target.blend = premultiplied;
      pipelines[entryPoint] = await device.createRenderPipelineAsync({
        layout,
        vertex,
        fragment: { module: shader, entryPoint, targets: [target] },
        primitive: {
          topology: "triangle-list",
          cullMode: isGlass
            ? entryPoint === "glassBack"
              ? "front"
              : "back"
            : "none",
        },
        multisample: {
          count: isLight || isGlass || entryPoint === "copyScene" ? 4 : 1,
        },
      });
    }),
  );

  function textures(sources = [], parameterBuffer = zeroBuffer) {
    return device.createBindGroup({
      layout: textureLayout,
      entries: [
        { binding: 0, resource: sampler },
        ...[0, 1, 2, 3].map((index) => ({
          binding: index + 1,
          resource: (sources[index] ?? dummy).createView(),
        })),
        { binding: 5, resource: { buffer: parameterBuffer } },
      ],
    });
  }

  const emptyGroup = textures();
  let targets = [],
    blurBuffers = [],
    backdrop,
    scene,
    multisample,
    backGroup,
    postprocessPasses = [],
    presentGroup,
    dustGroup;
  let visible = true,
    active = player.dataset.view === "prism",
    dirty = true,
    resized = true,
    lightDirty = true,
    lastFrame = 0,
    time = 0;
  let orbit = [0, 0],
    orbitTarget = [0, 0],
    aim = [...restingAim],
    aimTarget = [...restingAim],
    wall = [0, 0],
    dustWall = [0, 0];

  function render(now) {
    frame = 0;
    if (stopped || document.hidden || !visible || !active) return;
    const delta = lastFrame ? Math.min((now - lastFrame) / 1000, 0.1) : 0;
    const interactive =
      dirty ||
      resized ||
      aim.some((value, axis) => value !== aimTarget[axis]) ||
      orbit.some((value, axis) => value !== orbitTarget[axis]);
    if (
      !motion.matches &&
      delta > 0 &&
      delta < 1 / (interactive ? 60 : 30) - 0.001 &&
      !dirty &&
      !resized
    ) {
      frame = requestAnimationFrame(render);
      return;
    }
    lastFrame = now;
    if (!motion.matches) time += delta;
    if (resized) {
      const dpr = devicePixelRatio;
      if (!resolution?.matches) {
        if (resolution) resolution.onchange = null;
        resolution = matchMedia(`(resolution: ${dpr}dppx)`);
        resolution.onchange = resize;
      }
      const { width, height } = canvas.getBoundingClientRect();
      const scale = Math.min(
        dpr,
        Math.sqrt(maxRenderPixels / Math.max(width * height, 1)),
        device.limits.maxTextureDimension2D / Math.max(width, height, 1),
      );
      canvas.width = Math.max(1, Math.round(width * scale));
      canvas.height = Math.max(1, Math.round(height * scale));
      const aspect = canvas.width / canvas.height;
      let worst = 0;
      for (const x of [-1, 0, 1]) {
        for (const y of [-1, 0, 1]) {
          const camera = view(aspect, [x, y]);
          for (const horizontal of [-1, 1]) {
            for (const vertical of [-1, 1]) {
              const direction = camera.forward.map(
                (value, axis) =>
                  value +
                  (camera.right[axis] * horizontal * aspect +
                    camera.up[axis] * vertical) /
                    camera.focal,
              );
              const distance = -camera.position[2] / direction[2];
              worst = Math.max(
                worst,
                Math.abs(camera.position[0] + direction[0] * distance) / aspect,
                Math.abs(camera.position[1] + direction[1] * distance),
              );
            }
          }
        }
      }
      dustWall = [worst * 1.02 * aspect, worst * 1.02];
      wall = dustWall.map(
        (value) => value * Math.min(2.5, Math.max(1, 1 / aspect)),
      );
      lightDirty = true;
      for (const texture of targets) texture.destroy();
      for (const buffer of blurBuffers) buffer.destroy();
      targets = [];
      blurBuffers = [];
      postprocessPasses = [];
      const bloom = [];
      for (const [name, divisor, samples] of [
        ["multisample", 1, 4],
        ["backdrop", 1, 1],
        ["scene", 1, 1],
        ["extract", 2, 1],
        ["horizontal0", 2, 1],
        ["vertical0", 2, 1],
        ["horizontal1", 4, 1],
        ["vertical1", 4, 1],
        ["horizontal2", 8, 1],
        ["vertical2", 8, 1],
        ["particle", 16, 1],
        ["particleBlur", 16, 1],
      ]) {
        const texture = device.createTexture({
          label: name,
          size: [
            Math.max(1, Math.floor(canvas.width / divisor)),
            Math.max(1, Math.floor(canvas.height / divisor)),
          ],
          format: "rgba16float",
          sampleCount: samples,
          usage:
            GPUTextureUsage.RENDER_ATTACHMENT |
            (samples === 1 ? GPUTextureUsage.TEXTURE_BINDING : 0),
        });
        targets.push(texture);
      }
      [multisample, backdrop, scene] = targets;
      backGroup = textures([backdrop]);
      postprocessPasses.push({
        target: targets[3],
        pipeline: pipelines.bloomExtract,
        group: textures([scene]),
      });
      for (let level = 0; level < 3; level++) {
        const horizontal = targets[4 + level * 2],
          vertical = targets[5 + level * 2];
        for (const [target, source, direction] of [
          [
            horizontal,
            level ? targets[3 + level * 2] : targets[3],
            [1 / horizontal.width, 0],
          ],
          [vertical, horizontal, [0, 1 / vertical.height]],
        ]) {
          const buffer = device.createBuffer({
            size: 16,
            usage: GPUBufferUsage.UNIFORM,
            mappedAtCreation: true,
          });
          new Float32Array(buffer.getMappedRange()).set([...direction, 0, 0]);
          buffer.unmap();
          blurBuffers.push(buffer);
          postprocessPasses.push({
            target,
            pipeline: pipelines.bloomBlur,
            group: textures([source], buffer),
          });
        }
        bloom.push(vertical);
      }
      const [particle, particleBlur] = targets.slice(10);
      for (const [target, source, parameters] of [
        [particle, scene, [1 / particle.width, 1 / particle.height]],
        [particleBlur, particle, [1 / particle.width, 0]],
        [particle, particleBlur, [0, 1 / particle.height]],
      ]) {
        const buffer = device.createBuffer({
          size: 16,
          usage: GPUBufferUsage.UNIFORM,
          mappedAtCreation: true,
        });
        new Float32Array(buffer.getMappedRange()).set([...parameters, 0, 0]);
        buffer.unmap();
        blurBuffers.push(buffer);
        postprocessPasses.push({
          target,
          pipeline:
            source === scene ? pipelines.particleLight : pipelines.bloomBlur,
          group: textures([source], buffer),
        });
      }
      dustGroup = textures([targets[7], particle]);
      presentGroup = textures([scene, ...bloom]);
      postprocessPasses.push(
        {
          target: backdrop,
          pipeline: pipelines.composeScene,
          group: presentGroup,
        },
        { target: scene, pipeline: pipelines.antialiasScene, group: backGroup },
      );
      resized = false;
      dirty = true;
    }
    for (const [current, target, amount, snap] of [
      [aim, aimTarget, 0.12, 1e-4],
      [orbit, orbitTarget, 0.08, 3e-3],
    ]) {
      if (current.every((value, axis) => value === target[axis])) continue;
      const settled = current.every(
        (value, axis) => Math.abs(target[axis] - value) < snap,
      );
      const easing = 1 - (1 - amount) ** (delta * 60);
      for (let axis = 0; axis < 2; axis++)
        current[axis] = settled
          ? target[axis]
          : current[axis] + (target[axis] - current[axis]) * easing;
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
      uniforms.set([canvas.width, canvas.height, ...dustWall], 20);
      const m = camera.matrix;
      uniforms.set(
        triangle.flatMap(([x, y]) => {
          const z = planes[3][3],
            w = m[3] * x + m[7] * y + m[11] * z + m[15];
          return [
            ((m[0] * x + m[4] * y + m[8] * z + m[12]) / w) * 0.5 + 0.5,
            ((-m[1] * x - m[5] * y - m[9] * z - m[13]) / w) * 0.5 + 0.5,
          ];
        }),
        48,
      );
    }
    // prism.wgsl makes dust motion repeat every 3600 seconds, so this wrap is seamless.
    uniforms[24] = time % 3600;
    device.queue.writeBuffer(uniformBuffer, 0, uniforms);
    const encoder = device.createCommandEncoder();
    if (dirty) {
      let pass = encoder.beginRenderPass({
        colorAttachments: [
          {
            view: multisample.createView(),
            resolveTarget: backdrop.createView(),
            clearValue: [0, 0, 0, 1],
            loadOp: "clear",
            storeOp: "discard",
          },
        ],
      });
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
      pass = encoder.beginRenderPass({
        colorAttachments: [
          {
            view: multisample.createView(),
            resolveTarget: scene.createView(),
            clearValue: [0, 0, 0, 1],
            loadOp: "clear",
            storeOp: "discard",
          },
        ],
      });
      pass.setBindGroup(0, sceneGroup);
      pass.setBindGroup(1, backGroup);
      pass.setPipeline(pipelines.copyScene);
      pass.draw(3);
      pass.setPipeline(pipelines.glassFront);
      pass.setVertexBuffer(0, buffers.glass);
      pass.setIndexBuffer(buffers.indices, "uint16");
      pass.drawIndexed(glass.indices.length);
      pass.end();
      for (const step of postprocessPasses) {
        pass = encoder.beginRenderPass({
          colorAttachments: [
            {
              view: step.target.createView(),
              clearValue: [0, 0, 0, 1],
              loadOp: "clear",
              storeOp: "store",
            },
          ],
        });
        pass.setPipeline(step.pipeline);
        pass.setBindGroup(0, sceneGroup);
        pass.setBindGroup(1, step.group);
        pass.draw(3);
        pass.end();
      }
      dirty = false;
    }
    const pass = encoder.beginRenderPass({
      colorAttachments: [
        {
          view: context.getCurrentTexture().createView(),
          loadOp: "clear",
          storeOp: "store",
          clearValue: [0, 0, 0, 1],
        },
      ],
    });
    pass.setPipeline(pipelines.presentScene);
    pass.setBindGroup(0, sceneGroup);
    pass.setBindGroup(1, presentGroup);
    pass.draw(3);
    pass.setPipeline(pipelines.dustFragment);
    pass.setBindGroup(1, dustGroup);
    pass.draw(6, 2200);
    pass.end();
    device.queue.submit([encoder.finish()]);
    player.classList.add("ready");
    if (!motion.matches) frame = requestAnimationFrame(render);
  }

  function schedule() {
    if (stopped || document.hidden || !visible || !active) {
      cancelAnimationFrame(frame);
      frame = 0;
      lastFrame = 0;
    } else if (!frame) {
      frame = requestAnimationFrame(render);
    }
  }
  function resize() {
    resized = true;
    schedule();
  }
  resizeObserver = new ResizeObserver(resize);
  resizeObserver.observe(canvas);
  intersectionObserver = new IntersectionObserver((entries) => {
    visible = entries[0].isIntersecting;
    schedule();
  });
  intersectionObserver.observe(canvas);
  player.addEventListener("scenechange", () => {
    active = player.dataset.view === "prism";
    schedule();
  });
  document.addEventListener("visibilitychange", schedule);
  player.addEventListener("pointermove", (event) => {
    if (motion.matches || !active || event.pointerType !== "mouse") return;
    const bounds = canvas.getBoundingClientRect();
    const x = Math.min(
      1,
      Math.max(0, (event.clientX - bounds.left) / Math.max(bounds.width, 1)),
    );
    const y = Math.min(
      1,
      Math.max(0, (event.clientY - bounds.top) / Math.max(bounds.height, 1)),
    );
    aimTarget = [y, x];
    orbitTarget = [x * 2 - 1, y * 2 - 1];
    schedule();
  });
  player.addEventListener("pointerleave", () => {
    orbitTarget = [0, 0];
    schedule();
  });
  motion.addEventListener("change", () => {
    aim = [...restingAim];
    aimTarget = [...restingAim];
    orbit = [0, 0];
    orbitTarget = [0, 0];
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
