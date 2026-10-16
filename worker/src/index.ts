// Counts fwd installs. Each update check in the app also sends
// POST /v1/ping with a random install ID, its version, channel, install
// kind and macOS version; this records one data point and answers 204.
// The app gets release information and downloads from GitHub directly, so
// nothing about updates depends on this Worker.

const REPO = "kylefritz/fwd";

/** What one ping tells us, cleaned up for storage. */
export interface Ping {
  install: string;
  version: string;
  channel: string;
  kind: string;
  os: string;
  country: string;
  ip: string;
}

/** Headers come from the internet: keep them short and printable. */
function clean(value: string | null | undefined, max = 64): string {
  return (value ?? "").replace(/[^\x20-\x7e]/g, "").slice(0, max);
}

export function describePing(request: Request): Ping {
  const h = request.headers;
  const cf = (request as Request & { cf?: { country?: string } }).cf;
  return {
    install: clean(h.get("x-fwd-install")),
    version: clean(h.get("x-fwd-version")),
    channel: clean(h.get("x-fwd-channel"), 16),
    kind: clean(h.get("x-fwd-kind"), 16),
    os: clean(h.get("x-fwd-os"), 16),
    country: clean(cf?.country, 4),
    ip: clean(h.get("cf-connecting-ip")),
  };
}

/** Column order is the dataset's schema; append, never reorder. */
export function dataPoint(ping: Ping): AnalyticsEngineDataPoint {
  return {
    blobs: [ping.install, ping.version, ping.channel, ping.kind, ping.os, ping.country, ping.ip],
    doubles: [1],
    // The sampling key: one install's pings are kept or dropped together.
    indexes: [ping.install || ping.ip],
  };
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/" && request.method === "GET") {
      return Response.redirect(`https://github.com/${REPO}`, 302);
    }
    if (url.pathname !== "/v1/ping") return new Response("Not found", { status: 404 });
    if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });

    env.PINGS.writeDataPoint(dataPoint(describePing(request)));
    return new Response(null, { status: 204 });
  },
} satisfies ExportedHandler<Env>;
