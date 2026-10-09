// What the Worker hands the Phoenix release as its environment. Pure, so it is
// tested without the Workers runtime.

/** The vars and secrets the Phoenix app reads (see the repository README). */
export interface RunnerSettings {
  SECRET_KEY_BASE?: string;
  PHX_HOST?: string;
  PHX_URL_SCHEME?: string;
  PHX_URL_PORT?: string;
  UI_BASIC_AUTH?: string;
  REFERENCE_HOOK_SECRET?: string;
  ALLOW_PRIVATE_TARGETS?: string;
  MAX_CONCURRENT_RUNS?: string;
  REFERENCE_SERVER?: string;
}

const SETTINGS: (keyof RunnerSettings)[] = [
  "SECRET_KEY_BASE",
  "PHX_HOST",
  "PHX_URL_SCHEME",
  "PHX_URL_PORT",
  "UI_BASIC_AUTH",
  "REFERENCE_HOOK_SECRET",
  "ALLOW_PRIVATE_TARGETS",
  "MAX_CONCURRENT_RUNS",
  "REFERENCE_SERVER",
];

/**
 * The container's environment: the release listens on 0.0.0.0:4000, and every
 * setting that is set passes through. Unset or empty ones are left out so the
 * app's own defaults apply.
 */
export function containerEnvironment(env: RunnerSettings): Record<string, string> {
  const environment: Record<string, string> = { PORT: "4000", BIND_ADDRESS: "0.0.0.0" };
  for (const name of SETTINGS) {
    const value = env[name];
    if (value) environment[name] = value;
  }
  return environment;
}

/** Why the runner cannot start, or null. The release refuses to boot without a secret key base. */
export function setupProblem(env: RunnerSettings): string | null {
  return env.SECRET_KEY_BASE
    ? null
    : "SECRET_KEY_BASE is not set. Generate one with `mix phx.gen.secret` (or `openssl rand -base64 64`) " +
        "and store it with `npx wrangler secret put SECRET_KEY_BASE`.";
}

/** The public URL settings, taken from the address a request arrived on. */
export function publicUrl(requestUrl: string): Record<"PHX_HOST" | "PHX_URL_SCHEME" | "PHX_URL_PORT", string> {
  const url = new URL(requestUrl);
  const scheme = url.protocol.replace(":", "");
  return {
    PHX_HOST: url.hostname,
    PHX_URL_SCHEME: scheme,
    PHX_URL_PORT: url.port || (scheme === "https" ? "443" : "80"),
  };
}

/**
 * The request as the container should see it.
 *
 * The hop from the Worker to the container is plain http, so the app learns the
 * visitor's scheme from x-forwarded-proto (Plug.SSL's rewrite_on), set here and
 * never taken from the client.
 *
 * The container answers uncompressed. The Workers runtime adds Accept-Encoding to
 * its own fetch, and a compressed body would pass through to a client that never
 * asked for one, such as the suite itself, which deliberately sends no
 * Accept-Encoding. Cloudflare's edge compresses for the clients that do ask.
 */
export function forwarded(request: Request): Request {
  const headers = new Headers(request.headers);
  headers.set("x-forwarded-proto", new URL(request.url).protocol.replace(":", ""));
  headers.set("accept-encoding", "identity");
  return new Request(request, { headers });
}

const LOCAL_HOSTS = ["localhost", "127.0.0.1"];

/**
 * A redirect to https for a plain http visitor, or null. Done here rather than by
 * Plug.SSL so a redirect never wakes a sleeping container; GET and HEAD get a 301,
 * anything else a 308 so the method and body survive. Local addresses pass, for
 * wrangler dev.
 */
export function httpsRedirect(request: Request): Response | null {
  const url = new URL(request.url);
  if (url.protocol !== "http:" || LOCAL_HOSTS.includes(url.hostname)) return null;

  url.protocol = "https:";
  const status = request.method === "GET" || request.method === "HEAD" ? 301 : 308;
  return Response.redirect(url.toString(), status);
}
