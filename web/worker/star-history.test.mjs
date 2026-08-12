import assert from "node:assert/strict";
import test from "node:test";

import {
  fetchStarHistory,
  niceMaximum,
  renderStarHistorySvg,
} from "./index.mjs";

test("niceMaximum produces readable chart ceilings", () => {
  assert.equal(niceMaximum(0), 5);
  assert.equal(niceMaximum(6), 10);
  assert.equal(niceMaximum(13), 15);
  assert.equal(niceMaximum(31), 35);
});

test("renderStarHistorySvg creates branded light and dark artwork", () => {
  const stars = [
    "2026-06-10T00:00:00Z",
    "2026-06-15T00:00:00Z",
    "2026-07-01T00:00:00Z",
  ];
  const light = renderStarHistorySvg(stars, "light");
  const dark = renderStarHistorySvg(stars, "dark");

  assert.match(light, /TetherShot GitHub star history/);
  assert.match(light, /Every star is a clean/);
  assert.match(light, />capture\.<\/tspan>/);
  assert.match(light, /USB \+ WI-FI · LOCAL-FIRST/);
  assert.match(light, /IPHONE · SOURCE/);
  assert.match(light, /MAC · DESTINATION/);
  assert.match(dark, /PIXEL-PERFECT PNG/);
  assert.match(dark, /linearGradient id="capture-gradient"/);
  assert.doesNotMatch(`${light}${dark}`, /NaN|undefined/);
});

test("fetchStarHistory paginates, authenticates, and sorts", async () => {
  const firstPage = Array.from({ length: 100 }, (_, index) => ({
    starred_at: `2026-07-${String((index % 28) + 1).padStart(2, "0")}T00:00:00Z`,
  }));
  const responses = [
    new Response(JSON.stringify(firstPage)),
    new Response(JSON.stringify([{ starred_at: "2026-06-10T00:00:00Z" }])),
  ];
  const requests = [];
  const fakeFetch = async (url, options) => {
    requests.push({ url, options });
    return responses.shift();
  };

  const stars = await fetchStarHistory("test-token", fakeFetch);

  assert.equal(requests.length, 2);
  assert.match(requests[1].url, /page=2$/);
  assert.equal(requests[0].options.headers.Authorization, "Bearer test-token");
  assert.equal(stars[0], "2026-06-10T00:00:00Z");
  assert.equal(stars.length, 101);
});

test("fetchStarHistory requires a configured token", async () => {
  await assert.rejects(fetchStarHistory(undefined), /GITHUB_TOKEN is not configured/);
});
