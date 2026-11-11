// Pure ITS-login handler shared by `family-login` and `staff-login`. No Deno or Supabase
// imports, so it can be unit-tested anywhere; each index.ts wires in the real database.

export type LoginKind = "family" | "staff";

export interface Person {
  its_id: string;
  name: string;
  auth_id: string;
  is_active: boolean;
  family_size?: number;       // family only
  role?: "admin" | "cook";    // staff only
}

export interface LoginDeps {
  kind: LoginKind;
  isLocked(clientKey: string): Promise<boolean>;
  findPerson(its: string): Promise<Person | null>;
  recordAttempt(clientKey: string, its: string, success: boolean): Promise<void>;
  settings(): Promise<{ members_warn_over: number; login_lock_minutes: number }>;
  signToken(claims: Record<string, unknown>): Promise<string>;
  nowSeconds(): number;
  cors: Record<string, string>;
}

export const SESSION_HOURS: Record<LoginKind, number> = { family: 12, staff: 8 };
export const NOT_REGISTERED: Record<LoginKind, string> = {
  family: "This ITS is not registered as a Head of Family. Please ask your HOF to respond.",
  staff: "This ITS is not registered for admin access.",
};

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
  // (and all count as a failed attempt), so the lists cannot be probed.
  const person = /^[0-9]{8}$/.test(its) ? await d.findPerson(its) : null;
  if (!person || !person.is_active || (d.kind === "staff" && !person.role)) {
    await d.recordAttempt(key, its.slice(0, 16), false);
    return json({ error: "NOT_REGISTERED", message: NOT_REGISTERED[d.kind] }, 401, d.cors);
  }

  await d.recordAttempt(key, its, true);
  const iat = d.nowSeconds();
  const exp = iat + SESSION_HOURS[d.kind] * 3600;

  if (d.kind === "family") {
    const token = await d.signToken({
      aud: "authenticated",
      role: "authenticated",        // Postgres role PostgREST switches to
      sub: person.auth_id,          // uuid (auth.uid())
      its_id: person.its_id,        // read by public.current_its() in RLS
      app_role: "family",           // read by public.app_role()
      iat, exp,
    });
    return json(
      {
        access_token: token, token_type: "bearer", expires_at: exp,
        household: { its_id: person.its_id, name: person.name, family_size: person.family_size },
        members_warn_over: cfg.members_warn_over,
      },
      200, d.cors,
    );
  }

  // Staff token: NO its_id claim (staff are never mistaken for a family). The database
  // re-checks public.staff on every request, so deactivating a row cuts access at once.
  const token = await d.signToken({
    aud: "authenticated",
    role: "authenticated",
    sub: person.auth_id,
    app_role: person.role,
    staff_its: person.its_id,
    iat, exp,
  });
  return json(
    {
      access_token: token, token_type: "bearer", expires_at: exp,
      staff: { its_id: person.its_id, name: person.name, role: person.role },
    },
    200, d.cors,
  );
}