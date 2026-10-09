import { describe, expect, test } from "vitest";
import { containerEnvironment, forwarded, httpsRedirect, publicUrl, setupProblem } from "./environment";

const secrets = { SECRET_KEY_BASE: "k".repeat(64) };

describe("containerEnvironment", () => {
  test("binds the release to every IPv4 interface on port 4000", () => {
    expect(containerEnvironment(secrets)).toMatchObject({ PORT: "4000", BIND_ADDRESS: "0.0.0.0" });
  });

  test("passes the runner settings and secrets the Phoenix app reads", () => {
    const env = {
      ...secrets,
      PHX_HOST: "conformance.example.com",
      PHX_URL_SCHEME: "https",
      PHX_URL_PORT: "8443",
      UI_BASIC_AUTH: "turn:secret",
      REFERENCE_HOOK_SECRET: "hook",
      ALLOW_PRIVATE_TARGETS: "false",
      MAX_CONCURRENT_RUNS: "4",
      REFERENCE_SERVER: "true",
    };

    expect(containerEnvironment(env)).toEqual({ PORT: "4000", BIND_ADDRESS: "0.0.0.0", ...env });
  });

  test("leaves out settings that are unset or empty, so the app's defaults apply", () => {
    const environment = containerEnvironment({ ...secrets, PHX_HOST: "", UI_BASIC_AUTH: undefined });

    expect(Object.keys(environment).sort()).toEqual(["BIND_ADDRESS", "PORT", "SECRET_KEY_BASE"]);
  });

  test("never passes Worker bindings that are not settings", () => {
    expect(containerEnvironment({ ...secrets, RUNNER: {} } as never)).not.toHaveProperty("RUNNER");
  });
});

describe("setupProblem", () => {
  test("is null once SECRET_KEY_BASE is set", () => {
    expect(setupProblem(secrets)).toBeNull();
  });

  test("names the missing secret and the command that sets it", () => {
    expect(setupProblem({})).toBe(
      "SECRET_KEY_BASE is not set. Generate one with `mix phx.gen.secret` (or `openssl rand -base64 64`) " +
        "and store it with `npx wrangler secret put SECRET_KEY_BASE`.",
    );
  });
});

describe("publicUrl", () => {
  test("is the address a request arrived on, for the app's links and LiveView origin check", () => {
    expect(publicUrl("https://hcp-conformance.example.workers.dev/run?x=1")).toEqual({
      PHX_HOST: "hcp-conformance.example.workers.dev",
      PHX_URL_SCHEME: "https",
      PHX_URL_PORT: "443",
    });
  });

  test("keeps a local wrangler dev address as it is", () => {
    expect(publicUrl("http://localhost:8787/")).toEqual({
      PHX_HOST: "localhost",
      PHX_URL_SCHEME: "http",
      PHX_URL_PORT: "8787",
    });
  });
});

describe("forwarded", () => {
  test("tells the app which scheme the visitor used, so force_ssl redirects only plain http", () => {
    expect(forwarded(new Request("https://runner.example.com/run")).headers.get("x-forwarded-proto")).toBe("https");
    expect(forwarded(new Request("http://localhost:8787/")).headers.get("x-forwarded-proto")).toBe("http");
  });

  test("overwrites a scheme the client claimed", () => {
    const request = new Request("http://runner.example.com/", { headers: { "x-forwarded-proto": "https" } });

    expect(forwarded(request).headers.get("x-forwarded-proto")).toBe("http");
  });

  test("asks the container for an uncompressed body, whatever the client accepts", () => {
    // The Workers runtime adds Accept-Encoding on its own fetch; the edge compresses
    // for clients that ask, and a client that did not ask still gets plain bytes.
    const request = new Request("https://runner.example.com/", { headers: { "accept-encoding": "gzip, br" } });

    expect(forwarded(request).headers.get("accept-encoding")).toBe("identity");
    expect(forwarded(new Request("https://runner.example.com/")).headers.get("accept-encoding")).toBe("identity");
  });

  test("keeps the method, body and other headers", async () => {
    const request = new Request("https://runner.example.com/session", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", cookie: "_hcp=1" },
      body: "target=x",
    });
    const copy = forwarded(request);

    expect([copy.method, copy.url, copy.headers.get("cookie"), await copy.text()]).toEqual([
      "POST",
      "https://runner.example.com/session",
      "_hcp=1",
      "target=x",
    ]);
  });
});

describe("httpsRedirect", () => {
  test("sends a plain http visitor to https before the container is woken", () => {
    const response = httpsRedirect(new Request("http://runner.example.com/run?tab=log"));

    expect([response?.status, response?.headers.get("location")]).toEqual([
      301,
      "https://runner.example.com/run?tab=log",
    ]);
  });

  test("keeps the method and body of a form post with a 308", () => {
    expect(httpsRedirect(new Request("http://runner.example.com/session", { method: "POST" }))?.status).toBe(308);
  });

  test("lets https and local wrangler dev addresses through", () => {
    expect(httpsRedirect(new Request("https://runner.example.com/"))).toBeNull();
    expect(httpsRedirect(new Request("http://localhost:8787/"))).toBeNull();
    expect(httpsRedirect(new Request("http://127.0.0.1:8787/"))).toBeNull();
  });
});
