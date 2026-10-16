import { describe, expect, it } from "vitest";
import worker, { dataPoint, describePing } from "../src/index";

function ping(headers: Record<string, string>) {
  return describePing(new Request("https://fwd.kylefritz.co/v1/ping", { method: "POST", headers }));
}

describe("pings", () => {
  it("records what the app sends", () => {
    const p = ping({
      "x-fwd-install": "0b6c3f2e-1111-4222-8333-944455556666",
      "x-fwd-version": "0.1.1-beta.14",
      "x-fwd-channel": "beta",
      "x-fwd-kind": "release",
      "x-fwd-os": "26.1.0",
      "cf-connecting-ip": "203.0.113.7",
    });
    expect(dataPoint(p)).toEqual({
      blobs: ["0b6c3f2e-1111-4222-8333-944455556666", "0.1.1-beta.14", "beta", "release", "26.1.0", "", "203.0.113.7"],
      doubles: [1],
      indexes: ["0b6c3f2e-1111-4222-8333-944455556666"],
    });
  });

  it("keeps junk headers short and printable", () => {
    const p = ping({ "x-fwd-version": "1.0\u0007é" + "x".repeat(500), "x-fwd-channel": "beta".repeat(10) });
    expect(p.version.length).toBe(64);
    expect(p.version.startsWith("1.0x")).toBe(true);
    expect(p.channel.length).toBe(16);
  });

  it("samples by IP when there's no install ID", () => {
    expect(dataPoint(ping({ "cf-connecting-ip": "203.0.113.7" })).indexes).toEqual(["203.0.113.7"]);
  });
});

describe("routes", () => {
  const written: AnalyticsEngineDataPoint[] = [];
  const env = { PINGS: { writeDataPoint: (p?: AnalyticsEngineDataPoint) => void written.push(p!) } } as Env;
  const call = (path: string, method = "GET") =>
    worker.fetch(new Request(`https://fwd.kylefritz.co${path}`, { method }) as Parameters<typeof worker.fetch>[0], env);

  it("records a ping and says nothing back", async () => {
    const response = await call("/v1/ping", "POST");
    expect(response.status).toBe(204);
    expect(await response.text()).toBe("");
    expect(written.length).toBe(1);
  });

  it("answers nothing else", async () => {
    expect((await call("/v1/ping")).status).toBe(405);
    expect((await call("/v1/latest")).status).toBe(404);
    expect((await call("/")).status).toBe(302);
    expect(written.length).toBe(1);
  });
});
