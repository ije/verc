const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Cache-Control": "no-store",
};
const images = "https://image.tmdb.org/t/p/";

type TMDBJob = { job?: string; episode_count?: number };
type TMDBPerson = {
  name?: string;
  job?: string;
  jobs?: TMDBJob[];
  total_episode_count?: number;
};
type TMDBCredits = {
  cast?: (TMDBPerson | null)[];
  crew?: (TMDBPerson | null)[];
};
type TMDBResponse = TMDBCredits & {
  aggregate_credits?: TMDBCredits;
  backdrops?: ({ file_path?: string } | null)[];
  episodes?: ({
    season_number?: number;
    episode_number?: number;
    name?: string;
    still_path?: string | null;
  } | null)[];
  results?: ({
    id: number;
    media_type?: string;
    title?: string;
    name?: string;
    overview?: string;
    release_date?: string;
    first_air_date?: string;
    poster_path?: string | null;
    backdrop_path?: string | null;
  } | null)[];
};

function error(
  message: string,
  status: number,
  extraHeaders?: Record<string, string>,
) {
  return Response.json(
    { error: message },
    { status, headers: { ...headers, ...extraHeaders } },
  );
}

export default {
  async fetch(
    request: Request,
    env: { TMDB_API_READ_ACCESS_TOKEN?: string },
    ctx: ExecutionContext,
  ) {
    const url = new URL(request.url);
    if (url.pathname === "/verc.dmg")
      return Response.redirect(
        "https://github.com/ije/verc/releases/latest/download/Verc.dmg",
        302,
      );
    if (url.pathname !== "/tmdb") return error("Not found.", 404);
    if (request.method === "OPTIONS")
      return new Response(null, { status: 204, headers });
    if (request.method !== "POST")
      return error("Use POST.", 405, { Allow: "POST, OPTIONS" });
    if (
      request.headers
        .get("Content-Type")
        ?.split(";")[0]
        ?.trim()
        .toLowerCase() !== "application/json"
    ) {
      return error("Send an application/json body.", 415);
    }

    let body: unknown;
    try {
      let size = 0;
      const chunks = [];
      for await (const chunk of request.body ?? []) {
        size += chunk.byteLength;
        if (size > 4096) return error("Request body is too large.", 413);
        chunks.push(chunk);
      }
      body = JSON.parse(await new Blob(chunks).text());
    } catch {
      return error("Invalid JSON body.", 400);
    }
    if (!body || typeof body !== "object" || Array.isArray(body))
      return error("Send a JSON object.", 400);
    const {
      query: rawQuery,
      type = "multi",
      language = "en-US",
      id,
      season,
      credits = false,
    } = body as Record<string, unknown>;
    const query = typeof rawQuery === "string" ? rawQuery : "";
    if (typeof credits !== "boolean")
      return error("credits must be a boolean.", 400);
    const imageLookup = id !== undefined && season === undefined && !credits;
    const episodeLookup = season !== undefined;
    const titleType = type === "movie" || type === "tv";
    const validID = typeof id === "number" && Number.isSafeInteger(id) && id > 0;
    if (
      credits &&
      (!titleType || !validID || episodeLookup)
    ) {
      return error(
        "Credit lookup requires type movie or tv, a positive id, and no season.",
        400,
      );
    }
    if (imageLookup && (!titleType || !validID)) {
      return error(
        "Backdrop lookup requires type movie or tv and a positive id.",
        400,
      );
    }
    if (
      episodeLookup &&
      (type !== "tv" ||
        !validID ||
        typeof season !== "number" ||
        !Number.isInteger(season) ||
        season < 0 ||
        season > 1000)
    ) {
      return error(
        "Episode lookup requires type tv, a positive id, and a season between 0 and 1000.",
        400,
      );
    }
    if (
      !imageLookup &&
      !episodeLookup &&
      !credits &&
      (!query.trim() || query.length > 200)
    ) {
      return error("query must contain 1 to 200 characters.", 400);
    }
    if (type !== "multi" && !titleType)
      return error("type must be multi, movie, or tv.", 400);
    if (
      typeof language !== "string" ||
      !/^[a-z]{2}(?:-[A-Z]{2})?$/.test(language)
    ) {
      return error("language must be a language code such as en-US.", 400);
    }
    if (!env.TMDB_API_READ_ACCESS_TOKEN)
      return error("TMDB is not configured.", 503);

    const search = new URL(
      `https://api.themoviedb.org/3/${credits ? `${type}/${id}${type === "movie" ? "/credits" : ""}` : imageLookup ? `${type}/${id}/images` : episodeLookup ? `tv/${id}/season/${season}` : `search/${type}`}`,
    );
    search.search = new URLSearchParams(
      credits
        ? {
            language,
            ...(type === "tv"
              ? { append_to_response: "aggregate_credits" }
              : {}),
          }
        : imageLookup
          ? {}
          : episodeLookup
            ? { language }
            : { query: query.trim(), language, include_adult: "false" },
    ).toString();
    url.search = search.searchParams.toString();
    url.searchParams.set("type", type);
    if (imageLookup || episodeLookup) {
      url.searchParams.set("id", String(id));
      if (episodeLookup) url.searchParams.set("season", String(season));
      url.searchParams.set("images", "1");
    }
    if (credits) {
      url.searchParams.set("id", String(id));
      url.searchParams.set("credits", "1");
    }
    const cacheKey = new Request(url);
    const cached = await caches.default.match(cacheKey);
    if (cached) return cached;

    try {
      const upstream = await fetch(search, {
        headers: {
          Authorization: `Bearer ${env.TMDB_API_READ_ACCESS_TOKEN}`,
          Accept: "application/json",
        },
        signal: AbortSignal.timeout(8000),
      });
      if (upstream.status === 429) {
        const retry = upstream.headers.get("Retry-After");
        return error(
          "TMDB is busy. Try again later.",
          429,
          retry ? { "Retry-After": retry } : undefined,
        );
      }
      if (!upstream.ok) return error("TMDB search is unavailable.", 502);
      const data = await upstream.json<TMDBResponse | null>();
      let payload;
      if (credits) {
        const people = type === "tv" ? data?.aggregate_credits : data;
        if (!Array.isArray(people?.crew) || !Array.isArray(people?.cast))
          return error("Invalid TMDB response.", 502);
        const groups = [];
        const roles: [string, string[]][] = [
          ["Director", ["Director"]],
          ["Writer", ["Writer", "Screenplay", "Teleplay", "Story"]],
          ["Cast", []],
        ];
        for (const [role, jobs] of roles) {
          const ranked = (role === "Cast" ? people.cast : people.crew)
            .flatMap((person) => {
              if (typeof person?.name !== "string" || !person.name.trim())
                return [];
              const personJobs: TMDBJob[] =
                type === "tv" ? (person.jobs ?? []) : [{ job: person.job ?? "" }];
              const matches = personJobs.filter(
                (job) => typeof job.job === "string" && jobs.includes(job.job),
              );
              if (jobs.length && !matches.length) return [];
              return [
                {
                  name: person.name,
                  count:
                    role === "Cast"
                      ? (person.total_episode_count ?? 0)
                      : matches.reduce(
                          (total, job) => total + (job.episode_count ?? 0),
                          0,
                        ),
                },
              ];
            })
            .sort((a, b) => b.count - a.count);
          const names = [...new Set(ranked.map((person) => person.name))].slice(
            0,
            6,
          );
          if (names.length) groups.push({ role, names });
        }
        payload = { credits: groups };
      } else {
        if (imageLookup) {
          const list = data?.backdrops;
          if (!Array.isArray(list)) return error("Invalid TMDB response.", 502);
          const paths = list
            .map((item) => item?.file_path)
            .filter((path) => typeof path === "string" && path.startsWith("/"));
          payload = {
            backgroundURLs: [...new Set(paths)].map(
              (path) => `${images}w1280${path}`,
            ),
          };
        } else if (episodeLookup) {
          const list = data?.episodes;
          if (!Array.isArray(list)) return error("Invalid TMDB response.", 502);
          payload = {
            episodes: list.flatMap((item) =>
              item &&
              Number.isInteger(item.season_number) &&
              Number.isInteger(item.episode_number)
                ? [
                    {
                      season: item.season_number,
                      episode: item.episode_number,
                      title: typeof item.name === "string" ? item.name : "",
                      stillURL: item.still_path
                        ? `${images}w780${item.still_path}`
                        : null,
                    },
                  ]
                : [],
            ),
          };
        } else {
          const list = data?.results;
          if (!Array.isArray(list)) return error("Invalid TMDB response.", 502);
          const results = list.flatMap((item) => {
            const mediaType = type === "multi" ? item?.media_type : type;
            if (!item || (mediaType !== "movie" && mediaType !== "tv"))
              return [];
            return [
              {
                id: item.id,
                mediaType,
                title: item.title ?? item.name ?? "",
                overview: item.overview ?? "",
                releaseDate: item.release_date || item.first_air_date || null,
                posterURL: item.poster_path
                  ? `${images}w500${item.poster_path}`
                  : null,
                backgroundURL: item.backdrop_path
                  ? `${images}w1280${item.backdrop_path}`
                  : null,
                url: `https://www.themoviedb.org/${mediaType}/${item.id}`,
              },
            ];
          });
          payload = { results };
        }
      }
      const response = Response.json(payload, {
        headers: { ...headers, "Cache-Control": "public, max-age=3600" },
      });
      ctx.waitUntil(caches.default.put(cacheKey, response.clone()));
      return response;
    } catch (cause) {
      return error(
        "TMDB search is unavailable.",
        cause instanceof Error && cause.name === "TimeoutError" ? 504 : 502,
      );
    }
  },
};
