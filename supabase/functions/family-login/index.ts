// POST /functions/v1/family-login   { "its_id": "10234567" }
//
// Secrets (supabase secrets set ...):
//   FAMILY_JWT_SECRET  the project's JWT secret (Settings -> API -> JWT Secret). It MUST be the
//                      secret PostgREST verifies with, or the minted token will be rejected.
//   ALLOWED_ORIGIN     your site's origin (optional locally)
// Provided automatically by Supabase: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
import { createClient } from "npm:@supabase/supabase-js@2";
import { SignJWT } from "npm:jose@5";
import { corsHeaders } from "../_shared/cors.ts";
import { handleLogin, type LoginDeps } from "./handler.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);
const secret = new TextEncoder().encode(Deno.env.get("FAMILY_JWT_SECRET") ?? "");

const deps: LoginDeps = {
  cors: corsHeaders(),
  nowSeconds: () => Math.floor(Date.now() / 1000),

  async isLocked(key) {
    const { data, error } = await admin.rpc("login_is_locked", { p_client_key: key });
    if (error) throw error;
    return data === true;
  },
  async findHousehold(its) {
    const { data, error } = await admin
      .from("households")
      .select("its_id,name,family_size,auth_id,is_active")
      .eq("its_id", its)
      .maybeSingle();
    if (error) throw error;
    return data;
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

Deno.serve(async (req) => {
  try {
    if (secret.length === 0) throw new Error("FAMILY_JWT_SECRET is not set");
    return await handleLogin(req, deps);
  } catch (e) {
    console.error("family-login error", e);
    return new Response(JSON.stringify({ error: "SERVER_ERROR", message: "Something went wrong. Please try again." }), {
      status: 500,
      headers: { ...deps.cors, "Content-Type": "application/json" },
    });
  }
});
