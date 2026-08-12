const OWNER = "apoorvdarshan";
const REPOSITORY = "TetherShot";
const CACHE_SECONDS = 6 * 60 * 60;
const ONE_DAY = 24 * 60 * 60 * 1000;

const THEMES = {
  dark: {
    background: "#070709",
    panel: "#121216",
    border: "#302B48",
    grid: "#29263A",
    text: "#ECEAF6",
    muted: "#A5A2B8",
    device: "#191820",
  },
  light: {
    background: "#F6F5FA",
    panel: "#FFFFFF",
    border: "#D8D5E5",
    grid: "#E6E3EE",
    text: "#181621",
    muted: "#706C80",
    device: "#F1EFF6",
  },
};

export default {
  async fetch(request, env, context) {
    const url = new URL(request.url);

    if (url.pathname !== "/api/star-history.svg") {
      return env.ASSETS.fetch(request);
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD" },
      });
    }

    const themeName = url.searchParams.get("theme") === "dark" ? "dark" : "light";
    const cacheUrl = new URL(url);
    cacheUrl.search = `?theme=${themeName}&v=1`;
    const cacheKey = new Request(cacheUrl.toString(), { method: "GET" });
    const cached = await caches.default.match(cacheKey);

    if (cached) {
      return request.method === "HEAD"
        ? new Response(null, { status: cached.status, headers: cached.headers })
        : cached;
    }

    try {
      const stars = await fetchStarHistory(env.GITHUB_TOKEN);
      const response = svgResponse(renderStarHistorySvg(stars, themeName), CACHE_SECONDS);
      context.waitUntil(caches.default.put(cacheKey, response.clone()));

      return request.method === "HEAD"
        ? new Response(null, { status: response.status, headers: response.headers })
        : response;
    } catch (error) {
      console.error(JSON.stringify({
        event: "star_history_render_failed",
        message: error instanceof Error ? error.message : String(error),
      }));
      const response = svgResponse(renderErrorSvg(themeName), 60, 503);

      return request.method === "HEAD"
        ? new Response(null, { status: response.status, headers: response.headers })
        : response;
    }
  },
};

export async function fetchStarHistory(token, fetchImplementation = fetch) {
  if (!token) {
    throw new Error("GITHUB_TOKEN is not configured");
  }

  const stars = [];

  for (let page = 1; page <= 100; page += 1) {
    const response = await fetchImplementation(
      `https://api.github.com/repos/${OWNER}/${REPOSITORY}/stargazers?per_page=100&page=${page}`,
      {
        headers: {
          Accept: "application/vnd.github.star+json",
          Authorization: `Bearer ${token}`,
          "User-Agent": "tethershot-star-history",
          "X-GitHub-Api-Version": "2022-11-28",
        },
      },
    );

    if (!response.ok) {
      throw new Error(`GitHub returned ${response.status}`);
    }

    const payload = await response.json();

    if (!Array.isArray(payload)) {
      throw new Error("GitHub returned an unexpected response");
    }

    for (const item of payload) {
      if (typeof item?.starred_at === "string") {
        stars.push(item.starred_at);
      }
    }

    if (payload.length < 100) {
      return stars.sort((left, right) => left.localeCompare(right));
    }
  }

  throw new Error("Star history exceeded the pagination safety limit");
}

export function renderStarHistorySvg(starredAtValues, themeName = "light") {
  const theme = THEMES[themeName] ?? THEMES.light;
  const dark = themeName === "dark";
  const width = 960;
  const height = 520;
  const plot = { left: 72, top: 214, right: 888, bottom: 410 };
  const now = Date.now();
  const dates = starredAtValues
    .map((value) => new Date(value).getTime())
    .filter(Number.isFinite)
    .sort((left, right) => left - right);
  const rangeStart = Math.min((dates[0] ?? now) - ONE_DAY, now - 30 * ONE_DAY);
  const rangeEnd = Math.max(now, rangeStart + ONE_DAY);
  const yMaximum = niceMaximum(Math.max(dates.length, 1));
  const x = (timestamp) =>
    plot.left + ((timestamp - rangeStart) / (rangeEnd - rangeStart)) * (plot.right - plot.left);
  const y = (count) => plot.bottom - (count / yMaximum) * (plot.bottom - plot.top);
  const points = cumulativeSamples(dates, rangeStart, rangeEnd, 64).map(
    ([timestamp, count]) => [x(timestamp), y(count)],
  );
  const linePath = smoothPath(points);
  const areaPath = `${linePath} L${plot.right} ${plot.bottom} L${plot.left} ${plot.bottom} Z`;
  const currentStars = dates.length;
  const currentY = y(currentStars);
  const yGrid = tickValues(yMaximum, 6)
    .map((value) => {
      const position = y(value);
      return `<line x1="${plot.left}" y1="${position}" x2="${plot.right}" y2="${position}" class="grid"/>
      <text x="${plot.left - 16}" y="${position + 5}" text-anchor="end" class="axis">${value}</text>`;
    })
    .join("");
  const xLabels = dateTicks(rangeStart, rangeEnd, 4)
    .map((timestamp, index) => {
      const anchor = index === 0 ? "start" : index === 3 ? "end" : "middle";
      return `<text x="${x(timestamp)}" y="${plot.bottom + 34}" text-anchor="${anchor}" class="axis">${formatDate(timestamp, rangeEnd - rangeStart)}</text>`;
    })
    .join("");
  const frames = [0.26, 0.52, 0.76]
    .map((ratio) => {
      const [frameX, frameY] = points[Math.round((points.length - 1) * ratio)];
      return `<g transform="translate(${frameX} ${frameY})" filter="url(#soft-glow)">
        <rect x="-9" y="-12" width="18" height="24" rx="4" fill="${theme.panel}" stroke="#55D6FF" stroke-width="1.8"/>
        <path d="M-5 6 L-1 1 L2 4 L6 -2 V8 H-5Z" fill="url(#capture-gradient)" opacity=".9"/>
        <circle cx="4" cy="-6" r="2" fill="#F156D8"/>
      </g>`;
    })
    .join("");
  const ink = theme.text;

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-labelledby="title description">
  <title id="title">TetherShot GitHub star history</title>
  <desc id="description">${currentStars} GitHub stars over time for ${OWNER}/${REPOSITORY}.</desc>
  <defs>
    <linearGradient id="capture-gradient" x1="0" y1="0" x2="1" y2="0"><stop stop-color="#F156D8"/><stop offset=".42" stop-color="#9A63FF"/><stop offset=".74" stop-color="#2F5BFF"/><stop offset="1" stop-color="#55D6FF"/></linearGradient>
    <linearGradient id="capture-area" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#9A63FF" stop-opacity=".28"/><stop offset=".65" stop-color="#2F5BFF" stop-opacity=".08"/><stop offset="1" stop-color="#55D6FF" stop-opacity="0"/></linearGradient>
    <radialGradient id="stage-glow" cx="50%" cy="0%" r="85%"><stop stop-color="#9A63FF" stop-opacity="${dark ? ".13" : ".08"}"/><stop offset="1" stop-color="#9A63FF" stop-opacity="0"/></radialGradient>
    <pattern id="sensor-grid" width="24" height="24" patternUnits="userSpaceOnUse"><path d="M24 0 H0 V24" fill="none" stroke="#9A63FF" stroke-opacity="${dark ? ".055" : ".035"}" stroke-width="1"/></pattern>
    <filter id="beam-glow" x="-30%" y="-100%" width="160%" height="300%"><feGaussianBlur stdDeviation="5" result="blur"/><feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
    <filter id="soft-glow" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="2.4" result="blur"/><feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
    <clipPath id="plot"><rect x="${plot.left}" y="${plot.top - 18}" width="${plot.right - plot.left}" height="${plot.bottom - plot.top + 18}"/></clipPath>
    <style>
      .axis{fill:${theme.muted};font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px;font-weight:600}.grid{stroke:${theme.grid};stroke-width:1;stroke-dasharray:2 8;stroke-linecap:round}.headline{fill:${ink};font-family:'Instrument Serif',Georgia,serif;font-size:28px;font-weight:600;letter-spacing:-.4px}.body{fill:${theme.muted};font-family:Manrope,ui-sans-serif,system-ui,sans-serif;font-size:13.5px;font-weight:600}.utility{fill:${theme.muted};font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,monospace;font-size:10.5px;font-weight:700;letter-spacing:1.25px}.device-meta{fill:${theme.muted};font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,monospace;font-size:9px;font-weight:600;letter-spacing:.7px}
    </style>
  </defs>
  <rect width="960" height="520" rx="26" fill="${theme.background}"/>
  <rect x="16" y="16" width="928" height="488" rx="20" fill="${theme.panel}" stroke="${theme.border}" stroke-width="1.25"/>
  <rect x="17" y="17" width="926" height="486" rx="19" fill="url(#stage-glow)"/>
  <rect x="31" y="31" width="898" height="458" rx="14" fill="url(#sensor-grid)" stroke="${theme.border}" stroke-dasharray="2 7"/>

  <g transform="translate(61 42)">
    <circle cx="20" cy="20" r="19" fill="${theme.device}" stroke="#9A63FF"/>
    <g transform="translate(20 20)" fill="url(#capture-gradient)"><path d="M0 -14 L6 -4 L2 0 L-8 -8Z"/><path d="M12 -7 L8 5 L2 4 L2 -8Z"/><path d="M12 7 L0 14 L-3 8 L7 1Z"/><path d="M0 14 L-11 6 L-7 1 L4 8Z"/><path d="M-12 7 L-12 -6 L-6 -5 L-5 7Z"/><path d="M-12 -7 L0 -14 L3 -8 L-7 -1Z"/></g>
  </g>
  <text x="110" y="56" class="headline">Every star is a clean <tspan fill="#9A63FF" font-style="italic">capture.</tspan></text>
  <text x="111" y="80" class="body">From iPhone to Mac — pixel-perfect momentum, frame by frame.</text>
  <g transform="translate(785 39)">
    <rect width="116" height="48" rx="7" fill="${theme.device}" stroke="#9A63FF"/>
    <path d="M16 30 L23 17 L30 30Z" fill="url(#capture-gradient)" filter="url(#soft-glow)"/>
    <text x="42" y="30" fill="${ink}" font-family="Manrope,ui-sans-serif,system-ui,sans-serif" font-size="20" font-weight="800">${currentStars}</text>
    <text x="78" y="29" class="utility">STARS</text>
  </g>

  <g transform="translate(204 107)">
    <rect x="0" y="0" width="48" height="72" rx="11" fill="${theme.device}" stroke="#9A63FF" stroke-width="1.5"/>
    <rect x="6" y="8" width="36" height="54" rx="6" fill="${dark ? "#0A0912" : "#E8E6F0"}" stroke="${theme.border}"/>
    <rect x="17" y="4" width="14" height="3" rx="1.5" fill="${theme.muted}" opacity=".5"/>
    <path d="M10 52 C20 38 27 46 38 26" fill="none" stroke="url(#capture-gradient)" stroke-width="3"/>
  </g>
  <path d="M260 141 H675" stroke="${theme.border}" stroke-width="14" stroke-linecap="round"/>
  <path d="M260 141 H675" stroke="url(#capture-gradient)" stroke-width="2.5" stroke-linecap="round" filter="url(#beam-glow)"/>
  <g transform="translate(407 129)"><rect width="26" height="20" rx="3" fill="${theme.panel}" stroke="#F156D8"/><path d="M4 15 L10 9 L14 12 L21 5" fill="none" stroke="#55D6FF" stroke-width="1.5"/></g>
  <g transform="translate(504 129)"><rect width="26" height="20" rx="3" fill="${theme.panel}" stroke="#9A63FF"/><path d="M4 15 L10 9 L14 12 L21 5" fill="none" stroke="#55D6FF" stroke-width="1.5"/></g>
  <g transform="translate(682 112)">
    <rect width="86" height="58" rx="6" fill="${theme.device}" stroke="#55D6FF" stroke-width="1.5"/>
    <circle cx="9" cy="9" r="2" fill="#FF5F57"/><circle cx="16" cy="9" r="2" fill="#FEBC2E"/><circle cx="23" cy="9" r="2" fill="#28C840"/>
    <rect x="8" y="17" width="70" height="32" rx="3" fill="${dark ? "#0A0912" : "#E8E6F0"}"/>
    <path d="M14 41 C28 25 45 38 69 21" fill="none" stroke="url(#capture-gradient)" stroke-width="3"/>
    <path d="M30 58 H56 L62 64 H24Z" fill="${theme.device}" stroke="#55D6FF"/>
  </g>
  <text x="228" y="198" text-anchor="middle" class="utility">IPHONE · SOURCE</text>
  <text x="480" y="198" text-anchor="middle" class="utility">USB + WI-FI · LOCAL-FIRST</text>
  <text x="725" y="198" text-anchor="middle" class="utility">MAC · DESTINATION</text>

  ${yGrid}${xLabels}
  <g clip-path="url(#plot)"><path d="${areaPath}" fill="url(#capture-area)"/><path d="${linePath}" fill="none" stroke="#9A63FF" stroke-width="13" opacity=".1"/><path d="${linePath}" fill="none" stroke="url(#capture-gradient)" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" filter="url(#beam-glow)"/></g>
  ${frames}
  <g transform="translate(${plot.right} ${currentY})" filter="url(#soft-glow)"><circle r="10" fill="${theme.panel}" stroke="#55D6FF" stroke-width="2.5"/><path d="M0 -6 L2 -2 L7 -1 L3 2 L4 7 L0 4 L-4 7 L-3 2 L-7 -1 L-2 -2Z" fill="#9A63FF"/></g>

  <g transform="translate(60 467)"><text class="utility">PIXEL-PERFECT PNG</text><circle cx="180" cy="-3" r="2.5" fill="#9A63FF"/><text x="197" class="utility">YOUR FOLDER</text><circle cx="344" cy="-3" r="2.5" fill="#2F5BFF"/><text x="361" class="utility">YOUR CLIPBOARD</text></g>
  <g transform="translate(791 455)"><path d="M0 12 H88" stroke="url(#capture-gradient)" stroke-width="2" filter="url(#beam-glow)"/><path d="M81 6 L88 12 L81 18" fill="none" stroke="#55D6FF" stroke-width="2"/><text x="44" y="31" text-anchor="middle" class="device-meta">ONE CLICK</text></g>
</svg>`;
}

export function niceMaximum(value) {
  if (value <= 5) return 5;
  if (value <= 10) return 10;
  if (value <= 20) return Math.ceil(value / 5) * 5;

  const magnitude = 10 ** Math.floor(Math.log10(value));
  const fraction = value / magnitude;
  const step = magnitude * (fraction <= 1.25 ? 0.25 : 0.5);
  return Math.ceil(value / step) * step;
}

function smoothPath(points) {
  if (points.length === 0) return "";

  return points.reduce((path, [pointX, pointY], index) => {
    if (index === 0) return `M${pointX.toFixed(2)} ${pointY.toFixed(2)}`;
    const [previousX, previousY] = points[index - 1];
    const controlX = (previousX + pointX) / 2;
    return `${path} C${controlX.toFixed(2)} ${previousY.toFixed(2)} ${controlX.toFixed(2)} ${pointY.toFixed(2)} ${pointX.toFixed(2)} ${pointY.toFixed(2)}`;
  }, "");
}

function cumulativeSamples(stars, start, end, count) {
  let starIndex = 0;

  return dateTicks(start, end, count).map((timestamp) => {
    while (starIndex < stars.length && stars[starIndex] <= timestamp) {
      starIndex += 1;
    }
    return [timestamp, starIndex];
  });
}

function tickValues(maximum, count) {
  return Array.from({ length: count }, (_, index) =>
    Math.round((maximum / (count - 1)) * index),
  );
}

function dateTicks(start, end, count) {
  return Array.from(
    { length: count },
    (_, index) => start + ((end - start) / (count - 1)) * index,
  );
}

function formatDate(timestamp, range) {
  return new Intl.DateTimeFormat("en", {
    month: "short",
    ...(range >= 365 * ONE_DAY ? { year: "numeric" } : { day: "numeric" }),
    timeZone: "UTC",
  }).format(new Date(timestamp));
}

function svgResponse(svg, cacheSeconds, status = 200) {
  return new Response(svg, {
    status,
    headers: {
      "Cache-Control": `public, max-age=3600, s-maxage=${cacheSeconds}, stale-if-error=86400`,
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
      "Content-Type": "image/svg+xml; charset=utf-8",
      "Cross-Origin-Resource-Policy": "cross-origin",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function renderErrorSvg(themeName) {
  const theme = THEMES[themeName] ?? THEMES.light;

  return `<svg xmlns="http://www.w3.org/2000/svg" width="960" height="180" viewBox="0 0 960 180" role="img" aria-label="Star history is temporarily unavailable"><rect x=".5" y=".5" width="959" height="179" rx="18" fill="${theme.background}" stroke="${theme.border}"/><path d="M48 92 H196" stroke="#9A63FF" stroke-width="3"/><path d="M48 92 H196" stroke="#55D6FF" stroke-width="1" filter="url(#g)"/><text x="226" y="82" fill="${theme.text}" font-family="Georgia,serif" font-size="25" font-weight="600">The capture beam is refreshing</text><text x="226" y="116" fill="${theme.muted}" font-family="system-ui,sans-serif" font-size="16">The cached star history will return shortly.</text><defs><filter id="g"><feGaussianBlur stdDeviation="4"/></filter></defs></svg>`;
}
