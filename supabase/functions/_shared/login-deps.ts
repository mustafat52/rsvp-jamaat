import { createClient } from "npm:@supabase/supabase-js@2";
import { SignJWT } from "npm:jose@5";
import { corsHeaders } from "./cors.ts";
import type { LoginDeps, LoginKind, Person } from "./login-handler.ts";

// Secrets (supabase secrets set ...):
//   FAMILY_JWT_SECRET  the project's JWT secret (Settings -> API -> JWT Secret). It MUST be the
//                      secret PostgREST verifies with, or the minted token will be rejected.
//   ALLOWED_ORIGIN     your site's origin (optional locally)
// Provided automatically by Supabase: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
export function makeDeps(kind: LoginKind): LoginDeps & { secretOk: boolean } {
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const secret = new TextEncoder().encode(Deno.env.get("FAMILY_JWT_SECRET") ?? "");

  return {
    kind,
    secretOk: secret.length > 0,
    cors: corsHeaders(),
    nowSeconds: () => Math.floor(Date.now() / 1000),

    async isLocked(key) {
      const { data, error } = await admin.rpc("login_is_locked", { p_client_key: key });
      if (error) throw error;
      return data === true;
    },
    async findPerson(its): Promise<Person | null> {
      const q = kind === "family"
        ? admin.from("households").select("its_id,name,family_size,auth_id,is_active")
        : admin.from("staff").select("its_id,name,role,auth_id,is_active");
      const { data, error } = await q.eq("its_id", its).maybeSingle();
      if (error) throw error;
      return data as Person | null;
    },
    async recordAttempt(key, its, success) {
      const { error } = await admin.from("login_attempts").insert({ client_key: key, its_id: its, success });
      if (error) console.error("recordAttempt failed", error.message);   // never block login on logging
    },
    async settings() {
      const { data, error } = await admin
        .from("settings").select("members_warn_over,login_lock_minutes").single();
      if (error) throw error;
      return data;
    },
    signToken: (claims) => new SignJWT(claims).setProtectedHeader({ alg: "HS256", typ: "JWT" }).sign(secret),
  };
}