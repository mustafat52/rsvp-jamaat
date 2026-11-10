// Pure request handler for family login. No Deno or Supabase imports here, so it can be
// unit-tested anywhere; index.ts wires in the real database and token signer.

export interface Household {
  its_id: string;
  name: string;
  family_size: number;
  auth_id: string;
  is_active: boolean;
}

export interface LoginDeps {
  isLocked(clientKey: string): Promise<boolean>;
  findHousehold(its: string): Promise<Household | null>;
  recordAttempt(clientKey: string, its: string, success: boolean): Promise<void>;
  settings(): Promise<{ members_warn_over: number; login_lock_minutes: number }>;
  signToken(claims: Record<string, unknown>): Promise<string>;
  nowSeconds(): number;
  cors: Record<string, string>;
}

export const SESSION_HOURS = 12;
export const NOT_REGISTERED =
  "This ITS is not registered as a Head of Family. Please ask your HOF to respond.";

function json(body: unknown, status: number, cors: Record<string, string>, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, ...extra, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function clientKey(req: Request): string {
  const h = req.headers;
  return (
    h.get("cf-connecting-ip") ||
    h.get("x-forwarded-for")?.split(",")[0].trim() ||
    h.get("x-real-ip") ||
    "unknown"
  );
}

export async function handleLogin(req: Request, d: LoginDeps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: d.cors });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405, d.cors);

  let body: { its_id?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "BAD_REQUEST", message: "Send JSON: { \"its_id\": \"12345678\" }" }, 400, d.cors);
  }
  const its = String(body.its_id ?? "").trim();
  const key = clientKey(req);

  const cfg = await d.settings();
  if (await d.isLocked(key)) {
    return json(
      { error: "LOCKED", message: `Too many wrong attempts. Please try again in ${cfg.login_lock_minutes} minutes.`,
        retry_after_minutes: cfg.login_lock_minutes },
      429, d.cors, { "Retry-After": String(cfg.login_lock_minutes * 60) },
    );
  }

  // Wrong format, unknown ITS and inactive ITS all look identical to the caller
  // (and all count as a failed attempt), so the list cannot be probed.
  const household = /^[0-9]{8}$/.test(its) ? await d.findHousehold(its) : null;
  if (!household || !household.is_active) {
    await d.recordAttempt(key, its.slice(0, 16), false);
    return json({ error: "NOT_REGISTERED", message: NOT_REGISTERED }, 401, d.cors);
  }

  await d.recordAttempt(key, its, true);
  const iat = d.nowSeconds();
  const exp = iat + SESSION_HOURS * 3600;
  const token = await d.signToken({
    aud: "authenticated",
    role: "authenticated",       // Postgres role PostgREST switches to
    sub: household.auth_id,      // uuid (auth.uid())
    its_id: household.its_id,    // read by public.current_its() in RLS
    app_role: "family",          // read by public.app_role()
    iat,
    exp,
  });

  return json(
    {
      access_token: token,
      token_type: "bearer",
      expires_at: exp,
      household: { its_id: household.its_id, name: household.name, family_size: household.family_size },
      members_warn_over: cfg.members_warn_over,
    },
    200,
    d.cors,
  );
}
