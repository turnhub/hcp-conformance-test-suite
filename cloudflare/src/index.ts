import { Container, getContainer } from "@cloudflare/containers";
import { env } from "cloudflare:workers";
import { containerEnvironment, forwarded, httpsRedirect, publicUrl, setupProblem, type RunnerSettings } from "./environment";

export interface Env extends RunnerSettings {
  RUNNER: DurableObjectNamespace<Runner>;
}

/**
 * The Phoenix release built from ../Dockerfile. One instance serves every
 * request: the app is stateless, a run lives in the LiveView that started it,
 * and MAX_CONCURRENT_RUNS caps the runs it takes at once.
 */
export class Runner extends Container<Env> {
  override defaultPort = 4000;
  // A run takes a minute or two. An idle runner sleeps, and the next request
  // starts it again in a few seconds.
  override sleepAfter = "15m";
  override pingEndpoint = "localhost/health";
  override envVars = containerEnvironment(env);

  // Without a PHX_HOST var, the address the first request arrived on becomes the
  // public URL, so links, the LiveView origin check and the reference
  // implementation's base URL match workers.dev, or localhost under wrangler dev.
  // It applies when the container starts; a running one keeps its environment.
  override async fetch(request: Request): Promise<Response> {
    if (!this.envVars?.PHX_HOST) this.envVars = { ...this.envVars, ...publicUrl(request.url) };
    return super.fetch(request);
  }
}

export default {
  async fetch(request, env): Promise<Response> {
    const redirect = httpsRedirect(request);
    if (redirect) return redirect;

    const problem = setupProblem(env);
    if (problem) {
      return new Response(problem + "\n", { status: 503, headers: { "content-type": "text/plain" } });
    }
    // fetch, not containerFetch: it forwards the LiveView WebSocket upgrade too.
    return getContainer(env.RUNNER).fetch(forwarded(request));
  },
} satisfies ExportedHandler<Env>;
