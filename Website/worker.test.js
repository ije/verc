import assert from "node:assert/strict";
import { afterEach, beforeEach, mock, test } from "node:test";
import worker from "./worker.js";

let cache, calls, pending, upstream;
const originalCaches = globalThis.caches;

beforeEach(() => {
    cache = new Map();
    calls = [];
    pending = [];
    upstream = { crew: [], cast: [] };
    globalThis.caches = { default: {
        match: async (key) => cache.get(key.url)?.clone(),
        put: async (key, response) => { cache.set(key.url, response); },
    } };
    mock.method(globalThis, "fetch", async (url, options) => {
        calls.push({ url: new URL(url), options });
        if (upstream instanceof Error) throw upstream;
        return upstream instanceof Response ? upstream.clone() : Response.json(upstream);
    });
});

afterEach(() => {
    mock.restoreAll();
    globalThis.caches = originalCaches;
});

async function post(body) {
    const response = await worker.fetch(new Request("https://example.com/tmdb", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    }), { TMDB_API_READ_ACCESS_TOKEN: "test" }, { waitUntil: (task) => pending.push(task) });
    await Promise.all(pending);
    return response;
}

test("movie credits group and deduplicate people in role order", async () => {
    upstream = {
        crew: [
            { name: "Alice", job: "Director" }, { name: "Alice", job: "Screenplay" },
            { name: "Alice", job: "Writer" }, { name: "Bob", job: "Story" },
            { name: "Chris", job: "Producer" }, { name: "Dana", job: "Original Music Composer" },
            { name: "Unrelated", job: "Assistant Director" }, { name: "", job: "Writer" },
        ],
        cast: [{ name: "Erin" }, { name: "Frank" }],
    };
    const response = await post({ type: "movie", id: 603, credits: true });
    assert.deepEqual(await response.json(), { credits: [
        { role: "Director", names: ["Alice"] }, { role: "Writer", names: ["Alice", "Bob"] },
        { role: "Cast", names: ["Erin", "Frank"] }, { role: "Producer", names: ["Chris"] },
        { role: "Music", names: ["Dana"] },
    ] });
    assert.equal(calls[0].url.pathname, "/3/movie/603/credits");
    assert.equal(response.headers.get("Cache-Control"), "public, max-age=3600");
    assert.equal(response.headers.get("Access-Control-Allow-Origin"), "*");
    assert.ok(calls[0].options.signal instanceof AbortSignal);
});

test("TV credits include creators and rank each job by episode count", async () => {
    upstream = { created_by: [{ name: "Creator" }], aggregate_credits: {
        crew: [
            { name: "Guest", jobs: [{ job: "Director", episode_count: 1 }] },
            { name: "Lead", jobs: [{ job: "Director", episode_count: 10 }, { job: "Writer", episode_count: 1 }] },
            { name: "Writer", jobs: [{ job: "Teleplay", episode_count: 8 }] },
        ],
        cast: Array.from({ length: 8 }, (_, index) => ({ name: `Actor ${index}`, total_episode_count: index })),
    } };
    const { credits } = await (await post({ type: "tv", id: 1438, credits: true })).json();
    assert.deepEqual(credits[0], { role: "Creator", names: ["Creator"] });
    assert.deepEqual(credits[1], { role: "Director", names: ["Lead", "Guest"] });
    assert.deepEqual(credits[2], { role: "Writer", names: ["Writer", "Lead"] });
    assert.deepEqual(credits[3].names, ["Actor 7", "Actor 6", "Actor 5", "Actor 4", "Actor 3", "Actor 2"]);
    assert.equal(calls[0].url.pathname, "/3/tv/1438");
    assert.equal(calls[0].url.searchParams.get("append_to_response"), "aggregate_credits");
});

test("credits cache separates titles, media types, languages, and backdrop lookups", async () => {
    for (const body of [
        { type: "movie", id: 1, credits: true }, { type: "movie", id: 1, credits: true },
        { type: "movie", id: 2, credits: true }, { type: "movie", id: 1, credits: true, language: "fr-FR" },
    ]) assert.equal((await post(body)).status, 200);
    assert.equal(calls.length, 3);
    upstream = { aggregate_credits: { crew: [], cast: [] } };
    assert.equal((await post({ type: "tv", id: 1, credits: true })).status, 200);
    upstream = { backdrops: [{ file_path: "/one.jpg" }, { file_path: "/one.jpg" }] };
    assert.deepEqual(await (await post({ type: "movie", id: 1 })).json(), { backgroundURLs: ["https://image.tmdb.org/t/p/w1280/one.jpg"] });
    assert.equal(cache.size, 5);
});

test("search and season responses remain compatible", async () => {
    upstream = { results: [{ id: 603, media_type: "movie", title: "The Matrix", overview: "Overview", release_date: "1999-03-31", poster_path: "/poster.jpg" }, { id: 1, media_type: "person" }] };
    const { results } = await (await post({ query: "The Matrix" })).json();
    assert.equal(results.length, 1);
    assert.equal(results[0].posterURL, "https://image.tmdb.org/t/p/w500/poster.jpg");
    assert.equal(results[0].url, "https://www.themoviedb.org/movie/603");
    upstream = { episodes: [{ season_number: 1, episode_number: 1, name: "Pilot", still_path: "/still.jpg" }] };
    assert.deepEqual(await (await post({ type: "tv", id: 1, season: 1 })).json(), {
        episodes: [{ season: 1, episode: 1, title: "Pilot", stillURL: "https://image.tmdb.org/t/p/w780/still.jpg" }],
    });
    assert.equal(cache.size, 2);
});

test("invalid credit requests and oversized bodies never reach TMDB", async () => {
    for (const body of [
        { type: "movie", credits: true }, { type: "multi", id: 1, credits: true },
        { type: "tv", id: 1, season: 1, credits: true }, { type: "movie", id: -1, credits: true },
        { type: "movie", id: 1.5, credits: true }, { type: "movie", id: 1, credits: "true" },
        { type: "movie", id: 1, credits: true, language: "../en" },
    ]) assert.equal((await post(body)).status, 400);
    assert.equal((await post({ query: "x".repeat(4096) })).status, 413);
    assert.equal(calls.length, 0);
});

test("empty credits are cached but malformed responses and upstream errors are not", async () => {
    assert.deepEqual(await (await post({ type: "movie", id: 1, credits: true })).json(), { credits: [] });
    for (const data of [{}, { crew: [] }, null, new Response("", { status: 500 })]) {
        upstream = data;
        assert.equal((await post({ type: "movie", id: 2, credits: true })).status, 502);
    }
    upstream = new Response("", { status: 429, headers: { "Retry-After": "30" } });
    const response = await post({ type: "movie", id: 2, credits: true });
    assert.equal(response.status, 429);
    assert.equal(response.headers.get("Retry-After"), "30");
    upstream = new DOMException("Timed out", "TimeoutError");
    assert.equal((await post({ type: "movie", id: 2, credits: true })).status, 504);
    assert.equal(cache.size, 1);
});

test("CORS preflight remains available without authentication", async () => {
    const response = await worker.fetch(new Request("https://example.com/tmdb", { method: "OPTIONS" }), {}, {});
    assert.equal(response.status, 204);
    assert.equal(response.headers.get("Access-Control-Allow-Methods"), "POST, OPTIONS");
    assert.equal(calls.length, 0);
});
