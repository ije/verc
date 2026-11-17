const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
svg.classList.add("glass-filters");
svg.setAttribute("aria-hidden", "true");
svg.setAttribute("focusable", "false");
svg.innerHTML = "<defs></defs>";
document.body.append(svg);

const canvas = document.createElement("canvas"),
  context = canvas.getContext("2d"),
  filters = new WeakMap();
const observer = new ResizeObserver((entries) => {
  for (const { target, borderBoxSize } of entries) {
    const width = Math.round(borderBoxSize[0].inlineSize),
      height = Math.round(borderBoxSize[0].blockSize);
    if (!width || !height) continue;
    const radius = Math.min(
      parseFloat(getComputedStyle(target).borderTopLeftRadius),
      width / 2,
      height / 2,
    );
    const state = filters.get(target),
      size = `${width}:${height}:${radius}`;
    if (state.size === size) continue;
    state.size = size;
    canvas.width = width;
    canvas.height = height;
    const map = context.createImageData(width, height),
      rim = Math.min(12, radius),
      corner = Math.ceil(radius) || 1;
    new Uint32Array(map.data.buffer).fill(0xff808080);
    for (let y = 0; y < height; y++) {
      const full = y < rim || y + 1 > height - rim;
      for (let x = 0; x < width; x++) {
        if (!full && x === corner) x = Math.max(x, width - corner);
        const dx =
          x + 0.5 - Math.max(radius, Math.min(width - radius, x + 0.5));
        const dy =
          y + 0.5 - Math.max(radius, Math.min(height - radius, y + 0.5));
        const distance = Math.hypot(dx, dy),
          depth = radius - distance;
        const bend =
          distance && depth >= 0 && depth < rim
            ? (1 - depth / rim) ** 2 / distance
            : 0;
        const offset = (y * width + x) * 4;
        map.data[offset] = Math.round(128 - dx * bend * 127);
        map.data[offset + 1] = Math.round(128 - dy * bend * 127);
      }
    }
    context.putImageData(map, 0, 0);
    state.filter.innerHTML = `<feImage href="${canvas.toDataURL()}" width="100%" height="100%" preserveAspectRatio="none" result="map" />
            <feDisplacementMap in="SourceGraphic" in2="map" scale="${rim * 2}" xChannelSelector="R" yChannelSelector="G" />`;
    target.style.setProperty("--glass-filter", `url(#${state.filter.id})`);
  }
});

for (const [index, surface] of document.querySelectorAll(".glass").entries()) {
  const filter = document.createElementNS(svg.namespaceURI, "filter");
  filter.id = `glass-${index}`;
  filter.setAttribute("x", "0");
  filter.setAttribute("y", "0");
  filter.setAttribute("width", "100%");
  filter.setAttribute("height", "100%");
  filter.setAttribute("color-interpolation-filters", "sRGB");
  svg.firstElementChild.append(filter);
  filters.set(surface, { filter });
  observer.observe(surface, { box: "border-box" });
}
