import { expect, test } from "bun:test";
import { buildLight, lightLayout, view } from "./public/scene.js";
import fixtures from "./fixtures/prism.json";

// These reference vertices come from PrismScene.swift; update them when its optics change.
test.each(fixtures)("light and camera match Metal at $aim with aspect $aspect", ({ aim, aspect, wall, matrix, ranges }) => {
    const vertices = new Float32Array(lightLayout.vertexCount * 3);
    buildLight(aim, wall, vertices);
    expect(vertices.every(Number.isFinite)).toBe(true);
    for (const range of ranges) {
        let visible = 0;
        for (let index = range.start; index < range.start + range.count; index++) {
            if (vertices[index * 3 + 2] >= 0) visible++;
        }
        expect(visible).toBe(range.visible);
        for (const [index, ...expected] of range.samples) {
            for (let component = 0; component < 3; component++) {
                expect(Math.abs(vertices[index * 3 + component] - expected[component])).toBeLessThan(1e-5 * Math.max(1, Math.abs(expected[component])));
            }
        }
    }
    const camera = view(aspect, [aim[1] * 2 - 1, aim[0] * 2 - 1]);
    for (let index = 0; index < matrix.length; index++) expect(camera.matrix[index]).toBeCloseTo(matrix[index], 6);
});
