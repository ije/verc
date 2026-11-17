import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import worker from "./index.ts";

let cache, calls, pending, upstream;
const originalCaches = globalThis.caches;

beforeEach(() => {
  cache = new Map();
  calls = [];
  pending = [];
  upstream = { crew: [], cast: [] };
  globalThis.caches = {
    default: {
      match: async (key) => cache.get(key.url)?.clone(),
      put: async (key, response) => {
        cache.set(key.url, response);
      },
    },
  };
  spyOn(globalThis, "fetch").mockImplementation(async (url, options) => {
    calls.push({ url: new URL(url), options });
    if (upstream instanceof Error) throw upstream;
    return upstream instanceof Response
      ? upstream.clone()
      : Response.json(upstream);
  });
});

afterEach(() => {
  mock.restore();
  globalThis.caches = originalCaches;
});

async function post(body) {
  const response = await worker.fetch(
    new Request("https://example.com/tmdb", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }),
    { TMDB_API_READ_ACCESS_TOKEN: "test" },
    { waitUntil: (task) => pending.push(task) },
  );
  await Promise.all(pending);
  return response;
}

test("movie credits group and deduplicate people in role order", async () => {
  upstream = {
    crew: [
      { name: "Alice", job: "Director" },
      { name: "Alice", job: "Screenplay" },
      { name: "Alice", job: "Writer" },
      { name: "Bob", job: "Story" },
      { name: "Chris", job: "Producer" },
      { name: "Dana", job: "Original Music Composer" },
      { name: "Unrelated", job: "Assistant Director" },
      { name: "", job: "Writer" },
    ],
    cast: [{ name: "Erin" }, { name: "Frank" }],
  };
  const response = await post({ type: "movie", id: 603, credits: true });
  expect(await response.json()).toStrictEqual({
    credits: [
      { role: "Director", names: ["Alice"] },
      { role: "Writer", names: ["Alice", "Bob"] },
      { role: "Cast", names: ["Erin", "Frank"] },
    ],
  });
  expect(calls[0].url.pathname).toBe("/3/movie/603/credits");
  expect(response.headers.get("Cache-Control")).toBe("public, max-age=3600");
  expect(response.headers.get("Access-Control-Allow-Origin")).toBe("*");
  expect(calls[0].options.signal).toBeInstanceOf(AbortSignal);
});

test("TV credits rank each job by episode count", async () => {
  upstream = {
    aggregate_credits: {
      crew: [
        { name: "Guest", jobs: [{ job: "Director", episode_count: 1 }] },
        {
          name: "Lead",
          jobs: [
            { job: "Director", episode_count: 10 },
            { job: "Writer", episode_count: 1 },
          ],
        },
        { name: "Writer", jobs: [{ job: "Teleplay", episode_count: 8 }] },
      ],
      cast: Array.from({ length: 8 }, (_, index) => ({
        name: `Actor ${index}`,
        total_episode_count: index,
      })),
    },
  };
  const { credits } = await (
    await post({ type: "tv", id: 1438, credits: true })
  ).json();
  expect(credits.length).toBe(3);
  expect(credits[0]).toStrictEqual({
    role: "Director",
    names: ["Lead", "Guest"],
  });
  expect(credits[1]).toStrictEqual({
    role: "Writer",
    names: ["Writer", "Lead"],
  });
  expect(credits[2].names).toStrictEqual([
    "Actor 7",
    "Actor 6",
    "Actor 5",
    "Actor 4",
    "Actor 3",
    "Actor 2",
  ]);
  expect(calls[0].url.pathname).toBe("/3/tv/1438");
  expect(calls[0].url.searchParams.get("append_to_response")).toBe(
    "aggregate_credits",
  );
});

test("credits cache separates titles, media types, languages, and backdrop lookups", async () => {
  for (const body of [
    { type: "movie", id: 1, credits: true },
    { type: "movie", id: 1, credits: true },
    { type: "movie", id: 2, credits: true },
    { type: "movie", id: 1, credits: true, language: "fr-FR" },
  ])
    expect((await post(body)).status).toBe(200);
  expect(calls.length).toBe(3);
  upstream = { aggregate_credits: { crew: [], cast: [] } };
  expect((await post({ type: "tv", id: 1, credits: true })).status).toBe(200);
  upstream = {
    backdrops: [{ file_path: "/one.jpg" }, { file_path: "/one.jpg" }],
  };
  expect(await (await post({ type: "movie", id: 1 })).json()).toStrictEqual({
    backgroundURLs: ["https://image.tmdb.org/t/p/w1280/one.jpg"],
  });
  expect(cache.size).toBe(5);
});

test("search and season responses remain compatible", async () => {
  upstream = {
    results: [
      {
        id: 603,
        media_type: "movie",
        title: "The Matrix",
        overview: "Overview",
        release_date: "1999-03-31",
        poster_path: "/poster.jpg",
      },
      { id: 1, media_type: "person" },
    ],
  };
  const { results } = await (await post({ query: "The Matrix" })).json();
  expect(results.length).toBe(1);
  expect(results[0].posterURL).toBe(
    "https://image.tmdb.org/t/p/w500/poster.jpg",
  );
  expect(results[0].url).toBe("https://www.themoviedb.org/movie/603");
  upstream = {
    episodes: [
      {
        season_number: 1,
        episode_number: 1,
        name: "Pilot",
        still_path: "/still.jpg",
      },
    ],
  };
  expect(
    await (await post({ type: "tv", id: 1, season: 1 })).json(),
  ).toStrictEqual({
    episodes: [
      {
        season: 1,
        episode: 1,
        title: "Pilot",
        stillURL: "https://image.tmdb.org/t/p/w780/still.jpg",
      },
    ],
  });
  expect(cache.size).toBe(2);
});

test("episodes without integer numbers are dropped and titles default to empty", async () => {
  upstream = {
    episodes: [
      { season_number: 1, episode_number: 2, name: null, still_path: null },
      { season_number: null, episode_number: 3, name: "No season" },
      { season_number: 1, episode_number: "4", name: "String episode" },
      { season_number: 1, episode_number: 5.5, name: "Fraction" },
      null,
    ],
  };
  expect(
    await (await post({ type: "tv", id: 1, season: 1 })).json(),
  ).toStrictEqual({
    episodes: [{ season: 1, episode: 2, title: "", stillURL: null }],
  });
});

test("invalid credit requests and oversized bodies never reach TMDB", async () => {
  for (const body of [
    { type: "movie", credits: true },
    { type: "multi", id: 1, credits: true },
    { type: "tv", id: 1, season: 1, credits: true },
    { type: "movie", id: -1, credits: true },
    { type: "movie", id: 1.5, credits: true },
    { type: "movie", id: 1, credits: "true" },
    { type: "movie", id: 1, credits: true, language: "../en" },
  ])
    expect((await post(body)).status).toBe(400);
  expect((await post({ query: "x".repeat(4096) })).status).toBe(413);
  expect(calls.length).toBe(0);
});

test("empty credits are cached but malformed responses and upstream errors are not", async () => {
  expect(
    await (await post({ type: "movie", id: 1, credits: true })).json(),
  ).toStrictEqual({ credits: [] });
  for (const data of [
    {},
    { crew: [] },
    null,
    new Response("", { status: 500 }),
  ]) {
    upstream = data;
    expect((await post({ type: "movie", id: 2, credits: true })).status).toBe(
      502,
    );
  }
  upstream = new Response("", {
    status: 429,
    headers: { "Retry-After": "30" },
  });
  const response = await post({ type: "movie", id: 2, credits: true });
  expect(response.status).toBe(429);
  expect(response.headers.get("Retry-After")).toBe("30");
  upstream = new DOMException("Timed out", "TimeoutError");
  expect((await post({ type: "movie", id: 2, credits: true })).status).toBe(
    504,
  );
  expect(cache.size).toBe(1);
});

test("CORS preflight remains available without authentication", async () => {
  const response = await worker.fetch(
    new Request("https://example.com/tmdb", { method: "OPTIONS" }),
    {},
    {},
  );
  expect(response.status).toBe(204);
  expect(response.headers.get("Access-Control-Allow-Methods")).toBe(
    "POST, OPTIONS",
  );
  expect(calls.length).toBe(0);
});
