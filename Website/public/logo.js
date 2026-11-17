const logo = document.querySelector(".logo"), canvas = logo.querySelector("canvas");
const motion = matchMedia("(prefers-reduced-motion: reduce)");
let frame = 0, lastFrame = 0, elapsed = 0, visible = false, stopped = false;
let resizeObserver, intersectionObserver;

function stop() {
    stopped = true;
    cancelAnimationFrame(frame);
    resizeObserver?.disconnect();
    intersectionObserver?.disconnect();
    logo.classList.remove("ready");
}

try {
    const gl = canvas.getContext("webgl2", { alpha: false, antialias: false, depth: false, powerPreference: "low-power" });
    if (!gl) throw new Error("WebGL is unavailable.");
    const program = gl.createProgram();
    for (const [type, source] of [
        [gl.VERTEX_SHADER, `#version 300 es
            precision highp float;
            uniform vec2 points[16];
            out vec3 color;
            const vec3 colors[16] = vec3[16](
                vec3(0.02, 0.65, 1), vec3(0.10, 0.85, 1), vec3(0, 0.83, 0.96), vec3(0, 0.66, 1),
                vec3(0.46, 0.66, 1), vec3(0.43, 0.75, 1), vec3(0.02, 0.73, 1), vec3(0, 0.63, 0.98),
                vec3(0.85, 0.61, 1), vec3(1, 0.64, 0.97), vec3(0.88, 0.73, 1), vec3(0.16, 0.80, 1),
                vec3(1, 0.73, 0.96), vec3(1, 0.83, 0.43), vec3(1, 0.88, 0.60), vec3(1, 0.76, 0.94)
            );
            vec4 weights(float t) {
                float t2 = t * t, t3 = t2 * t;
                return vec4(-0.5 * t + t2 - 0.5 * t3, 1.0 - 2.5 * t2 + 1.5 * t3,
                            0.5 * t + 2.0 * t2 - 1.5 * t3, -0.5 * t2 + 0.5 * t3);
            }
            void main() {
                int quad = gl_VertexID / 6, corner = gl_VertexID % 6;
                vec2 uv = vec2(quad % 24 + ((22 >> corner) & 1), quad / 24 + ((52 >> corner) & 1)) / 8.0;
                ivec2 cell = min(ivec2(uv), ivec2(2));
                vec4 wx = weights(uv.x - float(cell.x)), wy = weights(uv.y - float(cell.y));
                vec2 position = vec2(0);
                color = vec3(0);
                for (int y = 0; y < 4; y++) {
                    for (int x = 0; x < 4; x++) {
                        ivec2 node = clamp(cell + ivec2(x, y) - 1, ivec2(0), ivec2(3));
                        int index = node.y * 4 + node.x;
                        float weight = wx[x] * wy[y];
                        position += points[index] * weight;
                        color += colors[index] * weight;
                    }
                }
                gl_Position = vec4(position * vec2(2, -2) + vec2(-1, 1), 0, 1);
            }`],
        [gl.FRAGMENT_SHADER, `#version 300 es
            precision mediump float;
            in vec3 color;
            out vec4 outputColor;
            void main() { outputColor = vec4(clamp(color, 0.0, 1.0), 1); }`],
    ]) {
        const shader = gl.createShader(type);
        gl.shaderSource(shader, source);
        gl.compileShader(shader);
        if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
        gl.attachShader(program, shader);
        gl.deleteShader(shader);
    }
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
    gl.useProgram(program);
    const location = gl.getUniformLocation(program, "points[0]");
    const points = new Float32Array([
        0, 0, 0.33, 0, 0.67, 0, 1, 0,
        0, 0.33, 0.33, 0.33, 0.67, 0.33, 1, 0.33,
        0, 0.67, 0.33, 0.67, 0.67, 0.67, 1, 0.67,
        0, 1, 0.33, 1, 0.67, 1, 1, 1,
    ]);

    function render(now) {
        frame = 0;
        if (!lastFrame || now - lastFrame >= 1000 / 30 - 1) {
            if (lastFrame) elapsed += (now - lastFrame) * 0.0009;
            lastFrame = now;
            const time = motion.matches ? 0 : elapsed;
            points[10] = 0.33 + 0.12 * Math.sin(time);
            points[11] = 0.33 + 0.12 * Math.cos(time * 0.8);
            points[12] = 0.67 + 0.12 * Math.cos(time * 0.7);
            points[13] = 0.33 + 0.12 * Math.sin(time * 0.9);
            points[18] = 0.33 + 0.12 * Math.cos(time * 0.9);
            points[19] = 0.67 + 0.12 * Math.sin(time * 0.7);
            points[20] = 0.67 + 0.12 * Math.sin(time * 0.8);
            points[21] = 0.67 + 0.12 * Math.cos(time);
            gl.uniform2fv(location, points);
            gl.drawArrays(gl.TRIANGLES, 0, 24 * 24 * 6);
            logo.classList.add("ready");
        }
        if (!motion.matches) frame = requestAnimationFrame(render);
    }

    function schedule() {
        cancelAnimationFrame(frame);
        frame = lastFrame = 0;
        if (!stopped && !document.hidden && visible) frame = requestAnimationFrame(render);
    }

    resizeObserver = new ResizeObserver(([entry]) => {
        const scale = Math.min(devicePixelRatio || 1, 2);
        canvas.width = Math.max(1, Math.round(entry.contentRect.width * scale));
        canvas.height = Math.max(1, Math.round(entry.contentRect.height * scale));
        gl.viewport(0, 0, canvas.width, canvas.height);
        schedule();
    });
    resizeObserver.observe(logo);
    intersectionObserver = new IntersectionObserver(([entry]) => {
        visible = entry.isIntersecting;
        schedule();
    });
    intersectionObserver.observe(logo);
    document.addEventListener("visibilitychange", schedule);
    motion.addEventListener("change", schedule);
    canvas.addEventListener("webglcontextlost", stop);
} catch (error) {
    console.warn("Verc logo:", error.message);
    stop();
}
