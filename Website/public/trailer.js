const player = document.querySelector(".player"),
    trailer = player.querySelector(".trailer"),
    playback = player.querySelector(".playback"),
    surface = playback.querySelector(".playback-surface"),
    status = playback.querySelector(".playback-status"),
    message = status.querySelector("span"),
    external = status.querySelector("a"),
    transport = playback.querySelector(".transport"),
    timeline = playback.querySelector(".timeline"),
    elapsed = playback.querySelector(".elapsed"),
    durationLabel = playback.querySelector(".duration"),
    volume = playback.querySelector(".volume-panel input"),
    volumeButton = playback.querySelector(".volume-button"),
    volumePanel = playback.querySelector(".volume-panel"),
    volumeLabel = volumePanel.querySelector("output"),
    mute = playback.querySelector(".mute-button"),
    captions = playback.querySelector(".captions-button"),
    captionsPanel = playback.querySelector(".captions-panel"),
    captionSize = captionsPanel.querySelector("select"),
    fullscreen = playback.querySelector(".fullscreen-button"),
    close = player.querySelector(".trailer-close");
let api, video, session = 0, progressTimer, hideTimer, loadTimer, scrubbing = false;

function showPanel(panel) {
    volumePanel.hidden = panel !== volumePanel;
    captionsPanel.hidden = panel !== captionsPanel;
    volumeButton.setAttribute("aria-expanded", String(!volumePanel.hidden));
    captions.setAttribute("aria-expanded", String(!captionsPanel.hidden));
}

function reveal() {
    clearTimeout(hideTimer);
    player.classList.remove("controls-hidden");
    if (video?.getPlayerState?.() !== 1 || scrubbing || !volumePanel.hidden || !captionsPanel.hidden ||
        transport.matches(":hover, :focus-within") || close.matches(":hover, :focus-visible")) return;
    hideTimer = setTimeout(() => player.classList.add("controls-hidden"), 2500);
}

function update() {
    const duration = video?.getDuration?.() || 0;
    const time = scrubbing ? Number(timeline.value) : video?.getCurrentTime?.() || 0;
    timeline.max = duration || 1;
    timeline.disabled = !duration;
    if (!scrubbing) timeline.value = time;
    timeline.style.setProperty("--progress", `${duration ? time / duration * 100 : 0}%`);
    for (const [label, seconds] of [[elapsed, time], [durationLabel, duration]]) {
        const value = Math.max(0, Math.floor(seconds));
        label.textContent = label === durationLabel && !duration
            ? "—" : `${Math.floor(value / 60)}:${String(value % 60).padStart(2, "0")}`;
    }
    timeline.setAttribute("aria-valuetext", `${elapsed.textContent} of ${durationLabel.textContent}`);
    const muted = video?.isMuted?.() || Number(volume.value) === 0;
    volumeButton.classList.toggle("muted", muted);
    volumeLabel.value = `${volume.value}%`;
    volume.style.setProperty("--volume", `${volume.value}%`);
    mute.classList.toggle("muted", muted);
    mute.title = muted ? "Unmute" : "Mute";
    mute.setAttribute("aria-label", mute.title);
    mute.setAttribute("aria-pressed", String(muted));
}

function reset() {
    session++;
    clearInterval(progressTimer);
    clearTimeout(loadTimer);
    clearTimeout(hideTimer);
    player.classList.remove("controls-hidden");
    playback.classList.remove("paused");
    surface.disabled = true;
    timeline.disabled = true;
    captions.disabled = true;
    scrubbing = false;
    showPanel();
    video?.destroy();
    video = null;
}

function fail() {
    reset();
    message.textContent = "This trailer cannot play here.";
    external.hidden = false;
    status.hidden = false;
}

player.addEventListener("playtrailer", async ({ detail: item }) => {
    if (!item?.trailerID || player.dataset.view === "trailer") return;
    const current = ++session;
    player.dataset.view = "trailer";
    player.querySelector(".gallery").hidden = true;
    player.querySelector(".poster-tooltip").hidden = true;
    trailer.hidden = playback.hidden = close.hidden = false;
    message.textContent = "Loading trailer…";
    external.href = `https://www.youtube.com/watch?v=${item.trailerID}`;
    external.hidden = true;
    status.hidden = false;
    surface.disabled = true;
    captions.disabled = true;
    timeline.value = 0;
    timeline.disabled = true;
    timeline.style.setProperty("--progress", "0%");
    elapsed.textContent = "0:00";
    durationLabel.textContent = "—";
    player.dispatchEvent(new Event("scenechange"));
    close.focus({ preventScroll: true });
    loadTimer = setTimeout(fail, 15000);
    try {
        api ??= new Promise((resolve, reject) => {
            if (window.YT?.Player) return resolve(window.YT);
            const script = document.createElement("script");
            script.src = "https://www.youtube.com/iframe_api";
            window.onYouTubeIframeAPIReady = () => resolve(window.YT);
            script.onerror = () => {
                script.remove();
                api = null;
                reject(new Error("Unable to load YouTube."));
            };
            document.head.append(script);
        });
        const YT = await api;
        if (current !== session) return;
        const frame = document.createElement("iframe");
        const params = new URLSearchParams({
            autoplay: "1", controls: "0", disablekb: "1", fs: "0", playsinline: "1",
            rel: "0", cc_load_policy: "1", enablejsapi: "1", origin: location.origin,
        });
        frame.src = `https://www.youtube-nocookie.com/embed/${item.trailerID}?${params}`;
        frame.title = `${item.title} — Official trailer`;
        frame.allow = "autoplay; encrypted-media";
        frame.referrerPolicy = "strict-origin-when-cross-origin";
        frame.tabIndex = -1;
        trailer.replaceChildren(frame);
        video = new YT.Player(frame, {
            events: {
                onReady({ target }) {
                    if (current !== session) return target.destroy();
                    clearTimeout(loadTimer);
                    target.setVolume(Number(volume.value));
                    surface.disabled = false;
                    target.playVideo();
                    update();
                },
                onStateChange({ data }) {
                    if (current !== session) return;
                    clearInterval(progressTimer);
                    status.hidden = data !== 3 && data !== -1;
                    message.textContent = "Loading trailer…";
                    playback.classList.toggle("paused", data === 0 || data === 2 || data === 5);
                    surface.setAttribute("aria-label", data === 0 ? "Replay trailer" : data === 1 ? "Pause trailer" : "Play trailer");
                    update();
                    if (data === 1) progressTimer = setInterval(update, 250);
                    reveal();
                },
                onAutoplayBlocked() {
                    if (current !== session) return;
                    status.hidden = true;
                    playback.classList.add("paused");
                    surface.setAttribute("aria-label", "Play trailer");
                    reveal();
                },
                onApiChange({ target }) {
                    if (current !== session) return;
                    captions.disabled = !target.getOptions().includes("captions");
                    if (!captions.disabled) target.setOption("captions", "fontSize", Number(captionSize.value));
                },
                onError() {
                    if (current === session) fail();
                },
            },
        });
    } catch {
        if (current === session) fail();
    }
});

player.addEventListener("scenechange", () => {
    if (player.dataset.view === "trailer") return;
    reset();
    trailer.replaceChildren();
    trailer.hidden = playback.hidden = close.hidden = true;
});

close.addEventListener("click", () => {
    if (document.fullscreenElement === player) document.exitFullscreen().catch(() => {});
    player.dispatchEvent(new Event("closetrailer"));
});
surface.addEventListener("click", () => {
    if (!volumePanel.hidden || !captionsPanel.hidden) {
        showPanel();
    } else if (video?.getPlayerState?.() === 1) video.pauseVideo();
    else video?.playVideo?.();
    reveal();
});
surface.addEventListener("dblclick", () => fullscreen.click());
for (const type of ["pointermove", "pointerdown", "focusin"]) {
    player.addEventListener(type, () => {
        if (player.dataset.view === "trailer") reveal();
    });
}
transport.addEventListener("pointerleave", reveal);
transport.addEventListener("focusout", () => requestAnimationFrame(reveal));
close.addEventListener("pointerleave", reveal);
volumeButton.addEventListener("click", () => {
    showPanel(volumePanel.hidden ? volumePanel : null);
    reveal();
});
volume.addEventListener("input", () => {
    video?.unMute?.();
    video?.setVolume?.(Number(volume.value));
    update();
});
mute.addEventListener("click", () => {
    if (video?.isMuted?.() || Number(volume.value) === 0) {
        if (Number(volume.value) === 0) volume.value = 100;
        video?.setVolume?.(Number(volume.value));
        video?.unMute?.();
    } else video?.mute?.();
    update();
    reveal();
});
captions.addEventListener("click", () => {
    showPanel(captionsPanel.hidden ? captionsPanel : null);
    reveal();
});
captionSize.addEventListener("change", () => {
    video?.setOption("captions", "fontSize", Number(captionSize.value));
});
timeline.addEventListener("input", () => {
    scrubbing = true;
    update();
    reveal();
});
timeline.addEventListener("change", () => {
    video?.seekTo?.(Number(timeline.value), true);
    scrubbing = false;
    reveal();
});
timeline.addEventListener("pointercancel", () => {
    scrubbing = false;
    update();
    reveal();
});
fullscreen.hidden = !document.fullscreenEnabled;
fullscreen.addEventListener("click", async () => {
    try {
        if (document.fullscreenElement === player) await document.exitFullscreen();
        else await player.requestFullscreen();
    } catch {
        reveal();
    }
});
document.addEventListener("fullscreenchange", () => {
    const label = document.fullscreenElement === player ? "Exit fullscreen" : "Enter fullscreen";
    fullscreen.setAttribute("aria-label", label);
    fullscreen.title = `${label} · F`;
    reveal();
});
player.addEventListener("keydown", (event) => {
    if (player.dataset.view !== "trailer") return;
    if (event.key === "Escape") {
        event.preventDefault();
        event.stopImmediatePropagation();
        if (document.fullscreenElement === player) fullscreen.click();
        else close.click();
        return;
    }
    if (event.target.matches("input, select") || event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.code === "Space" && event.target.closest("button")) return;
    if (event.code === "Space" || event.key.toLowerCase() === "k") surface.click();
    else if (event.key.toLowerCase() === "m") mute.click();
    else if (event.key.toLowerCase() === "f") fullscreen.click();
    else if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
        video?.seekTo?.(Math.max(0, Math.min(video.getDuration(), video.getCurrentTime() + (event.key === "ArrowLeft" ? -5 : 5))), true);
        update();
    } else return;
    event.preventDefault();
    reveal();
});
