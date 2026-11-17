const player = document.querySelector(".player"),
  gallery = player.querySelector(".gallery"),
  library = player.querySelector(".library");
const dots = [...player.querySelectorAll(".page-dot")],
  toggle = player.querySelector(".library-toggle"),
  search = library.querySelector("input");
const tooltip = player.querySelector(".poster-tooltip"),
  title = player.querySelector(".window-title");
const track = gallery.querySelector(".gallery-track"),
  details = track.querySelector(".details"),
  credits = gallery.querySelector(".credits"),
  trailerButton = gallery.querySelector(".trailer-button");
const posters = library.querySelector(".posters"),
  count = library.querySelector(".count"),
  noResults = library.querySelector(".no-results");
const windowUI = player.querySelector(".window-ui"),
  metrics = document.createElement("canvas").getContext("2d");
let items = [],
  selected = 0;

function resize() {
  const scale = Math.min(1, player.clientWidth / 640, player.clientHeight / 360);
  const width = player.clientWidth / scale,
    height = player.clientHeight / scale;
  const cardWidth = Math.min(
    640,
    Math.max(280, width * 0.64),
    (Math.max(72, height - 200) * 16) / 9,
  );
  const cardHeight = (cardWidth * 9) / 16,
    posterWidth = (cardHeight * 2) / 3;
  windowUI.style.width = `${width}px`;
  windowUI.style.height = `${height}px`;
  windowUI.style.transform = `scale(${scale})`;
  for (const [key, value] of Object.entries({
    "card-width": cardWidth,
    "card-height": cardHeight,
    "poster-width": posterWidth,
    "poster-gap": cardHeight * 0.05,
    "info-width": Math.min(
      640,
      Math.max(280, width * 0.48),
      width - 80 - posterWidth - cardHeight * 0.05 - 40 - 128,
    ),
    "gallery-top": 64 + Math.max(0, (height - 160 - cardHeight - 32) / 2),
    "heading-size": cardHeight < 270 ? 24 : 32,
  }))
    windowUI.style.setProperty(`--${key}`, `${value}px`);
  for (const [index, people] of credits.querySelectorAll("dd").entries()) {
    const names = items[selected - 1]?.credits[index].names;
    if (!names) continue;
    const text = people.querySelector(".names"),
      remaining = people.querySelector(".remaining");
    metrics.font = getComputedStyle(people).font;
    let count = Math.min(3, names.length);
    while (
      count > 0 &&
      metrics.measureText(names.slice(0, count).join(", ")).width +
        (count < names.length
          ? 6 + metrics.measureText(`+${names.length - count}`).width
          : 0) >
        people.clientWidth
    )
      count--;
    text.textContent = names.slice(0, count).join(", ");
    text.hidden = count === 0;
    remaining.textContent =
      count < names.length ? `+${names.length - count}` : "";
    remaining.hidden = count === names.length;
  }
}

new ResizeObserver(resize).observe(player);
new IntersectionObserver(
  ([entry]) => entry.target.classList.toggle("expanded", entry.isIntersecting),
  { threshold: 0.85 },
).observe(player.parentElement);

trailerButton.addEventListener("click", () => {
  player.dispatchEvent(
    new CustomEvent("playtrailer", { detail: items[selected - 1] }),
  );
});
player.addEventListener("closetrailer", () => {
  select(selected);
  trailerButton.focus({ preventScroll: true });
});

function select(index) {
  selected = index;
  const item = items[index - 1];
  player.dataset.view = item ? "gallery" : "prism";
  gallery.hidden = !item;
  library.hidden = true;
  tooltip.hidden = true;
  title.textContent = item?.title ?? "";
  toggle.setAttribute("aria-pressed", "false");
  dots.forEach((dot, i) => {
    dot.classList.toggle("selected", i === index);
    dot.setAttribute("aria-pressed", String(i === index));
  });
  if (item) {
    gallery.querySelector(".backdrop").src = item.backgroundURL;
    gallery.querySelector(".poster").src = item.posterURL;
    gallery.querySelector("h2").textContent = item.title;
    gallery.querySelector(".metadata").textContent =
      `${item.releaseDate.slice(0, 4)} · ${item.mediaType === "movie" ? "Movie" : "TV Show"}`;
    gallery.querySelector(".overview").textContent = item.overview;
    const link = gallery.querySelector(".tmdb-link");
    link.href = item.url;
    link.setAttribute("aria-label", `Open ${item.title} on TMDB`);
    const roles = document.createDocumentFragment();
    for (const credit of item.credits) {
      const role = document.createElement("dt"),
        people = document.createElement("dd"),
        names = document.createElement("span");
      role.textContent = credit.role;
      people.title = credit.names.join(", ");
      people.setAttribute("aria-label", people.title);
      names.className = "names";
      people.append(names);
      const remaining = document.createElement("span");
      remaining.className = "remaining";
      people.append(remaining);
      roles.append(role, people);
    }
    credits.replaceChildren(roles);
    const cards = document.createDocumentFragment();
    for (const media of item.media) {
      const card = document.createElement("a"),
        image = new Image(),
        name = document.createElement("strong");
      card.className = "media-card";
      card.href = media.url;
      card.target = "_blank";
      card.rel = "noreferrer";
      card.setAttribute("aria-label", `Open ${media.title} on TMDB`);
      image.src = media.stillURL ?? item.backgroundURL;
      image.alt = "";
      image.width = 780;
      image.height = 439;
      image.loading = "lazy";
      image.decoding = "async";
      image.draggable = false;
      name.textContent = media.title;
      card.append(image, name);
      cards.append(card);
    }
    track.replaceChildren(details, cards);
    track.setAttribute(
      "aria-label",
      `${item.title} ${item.mediaType === "tv" ? "episodes" : "gallery"}`,
    );
    track.scrollLeft = 0;
    resize();
  }
  player.dispatchEvent(new Event("scenechange"));
}

try {
  const response = await fetch("/library.json");
  if (!response.ok) throw new Error("Unable to load the preview library.");
  items = await response.json();
  count.textContent =
    `${items.length} ${items.length === 1 ? "item" : "items"}`;
  for (const [index, item] of items.entries()) {
    if (dots.length < 5) {
      const dot = document.createElement("button");
      dot.className = "page-dot";
      dot.setAttribute("aria-label", `Show ${item.title}`);
      dot.setAttribute("aria-pressed", "false");
      dot.append(document.createElement("i"));
      toggle.before(dot);
      dots.push(dot);
    }
    const card = document.createElement("button");
    card.className = "library-card";
    card.setAttribute("aria-label", `Open ${item.title}`);
    const poster = new Image();
    poster.src = item.posterURL;
    poster.alt = "";
    poster.width = 200;
    poster.height = 300;
    const name = document.createElement("strong"),
      year = document.createElement("span");
    name.textContent = item.title;
    year.textContent = item.releaseDate.slice(0, 4);
    card.append(poster, name, year);
    card.addEventListener("click", () => {
      select(index + 1);
      (dots[index + 1] ?? track).focus({ preventScroll: true });
    });
    posters.append(card);
  }
  for (const [index, dot] of dots.entries()) {
    dot.addEventListener("click", () => select(index));
    dot.addEventListener("pointerenter", () => {
      if (!index || !library.hidden) return;
      tooltip.querySelector("img").src = items[index - 1].posterURL;
      new Image().src = items[index - 1].backgroundURL;
      const bounds = windowUI.getBoundingClientRect(),
        dotBounds = dot.getBoundingClientRect();
      tooltip.style.left = `${((dotBounds.left + dotBounds.width / 2 - bounds.left) * windowUI.clientWidth) / bounds.width}px`;
      tooltip.hidden = false;
    });
    dot.addEventListener("pointerleave", () => {
      tooltip.hidden = true;
    });
  }
  let lastScrollTime = -Infinity,
    distance = 0,
    scrolled = false;
  player.querySelector(".dock").addEventListener(
    "wheel",
    (event) => {
      if (event.ctrlKey || event.buttons) return;
      event.preventDefault();
      const delta =
        Math.abs(event.deltaX) > Math.abs(event.deltaY)
          ? event.deltaX
          : event.deltaY;
      if (event.timeStamp - lastScrollTime > 250 || delta * distance < 0) {
        distance = 0;
        scrolled = false;
      }
      lastScrollTime = event.timeStamp;
      if (event.deltaMode === 0) {
        if (scrolled) return;
        distance += delta;
        if (Math.abs(distance) < 24) return;
        scrolled = true;
      } else {
        distance = delta;
        if (!distance) return;
      }
      const index = selected + Math.sign(distance);
      if (index >= 0 && index < dots.length) select(index);
    },
    { passive: false },
  );
  toggle.addEventListener("click", () => {
    if (!library.hidden) {
      select(selected);
      return;
    }
    gallery.hidden = true;
    library.hidden = false;
    tooltip.hidden = true;
    player.dataset.view = "library";
    title.textContent = "Library";
    toggle.setAttribute("aria-pressed", "true");
    dots.forEach((dot) => {
      dot.classList.remove("selected");
      dot.setAttribute("aria-pressed", "false");
    });
    player.dispatchEvent(new Event("scenechange"));
    search.focus({ preventScroll: true });
  });
  const cards = [...posters.children],
    titles = items.map((item) => item.title.toLowerCase());
  search.addEventListener("input", () => {
    const query = search.value.trim().toLowerCase();
    let matches = 0;
    for (const [index, card] of cards.entries()) {
      card.hidden = !titles[index].includes(query);
      if (!card.hidden) matches++;
    }
    count.textContent = `${matches} ${matches === 1 ? "item" : "items"}`;
    noResults.hidden = matches !== 0;
  });
  let drag = null,
    dragged = false;
  track.addEventListener("pointerdown", (event) => {
    dragged = false;
    if (
      event.pointerType !== "mouse" ||
      event.button !== 0 ||
      event.target.closest(".media-actions")
    )
      return;
    drag = { x: event.clientX, scroll: track.scrollLeft };
  });
  track.addEventListener("pointerleave", () => {
    if (!dragged) drag = null;
  });
  track.addEventListener("pointermove", (event) => {
    if (!drag) return;
    const offset =
      ((event.clientX - drag.x) * windowUI.clientWidth) /
      windowUI.getBoundingClientRect().width;
    if (!dragged && Math.abs(offset) < 5) return;
    dragged = true;
    track.setPointerCapture(event.pointerId);
    track.classList.add("dragging");
    track.scrollLeft = drag.scroll - offset;
    event.preventDefault();
  });
  for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) {
    track.addEventListener(type, () => {
      drag = null;
      track.classList.remove("dragging");
    });
  }
  track.addEventListener("dragstart", (event) => event.preventDefault());
  track.addEventListener("click", (event) => {
    if (dragged) {
      event.preventDefault();
      dragged = false;
    }
  });
  player.addEventListener("keydown", (event) => {
    if (player.dataset.view === "trailer") return;
    if (event.key === "Escape") {
      select(0);
      dots[0].focus({ preventScroll: true });
    }
    if (event.target instanceof HTMLInputElement || !library.hidden) return;
    if (event.key === "ArrowRight" || event.key === "ArrowLeft") {
      if (track.contains(event.target)) {
        event.preventDefault();
        track.scrollBy({
          left:
            (parseFloat(windowUI.style.getPropertyValue("--card-width")) + 32) *
            (event.key === "ArrowRight" ? 1 : -1),
          behavior: matchMedia("(prefers-reduced-motion: reduce)").matches
            ? "instant"
            : "smooth",
        });
        return;
      }
      if (!dots.includes(event.target)) return;
      event.preventDefault();
      select(
        (selected + (event.key === "ArrowRight" ? 1 : dots.length - 1)) %
          dots.length,
      );
      dots[selected].focus({ preventScroll: true });
    }
  });
} catch (error) {
  console.warn("Verc library:", error.message);
  for (const button of [...dots.slice(1), toggle]) button.disabled = true;
}
