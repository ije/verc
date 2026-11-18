import { WaveController } from "./distortion-waves/controller.js";

const download = document.querySelector(".download");
const wave = new WaveController(download, download.querySelector(".download-content"));
wave.update({
  type: "center",
  palette: "colorful",
  prewarm: false,
  live: false,
  resolution: Math.min(devicePixelRatio, 2),
  waveStyle: {
    anticipation: 0.1,
    travel: 2.65,
    lensWidth: 60,
    aberration: 0.45,
    strength: 0.85,
    rimStrength: 0.32,
    rimWidth: 3,
    rimFade: 1.5,
    hairlineLinger: 0.06,
    hairlineFade: 1.35,
    particleCount: 18,
    particleLife: 1.45,
  },
});

download.addEventListener("click", (event) => {
  if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
    return;
  const { left, top, width, height } = download.getBoundingClientRect();
  const x = event.detail ? (event.clientX - left) / width : 0.5;
  const y = event.detail ? (event.clientY - top) / height : 0.5;
  wave.play({
    source: { x: x * download.clientWidth, y: y * download.clientHeight, w: 0, h: 0 },
  });
});
