// POST /functions/v1/staff-login   { "its_id": "30464909" }
import { handleLogin } from "../_shared/login-handler.ts";
import { makeDeps } from "../_shared/login-deps.ts";

const deps = makeDeps("staff");

Deno.serve(async (req) => {
  try {
    if (!deps.secretOk) throw new Error("FAMILY_JWT_SECRET is not set");
    return await handleLogin(req, deps);
  } catch (e) {
    console.error("staff-login error", e);
    return new Response(JSON.stringify({ error: "SERVER_ERROR", message: "Something went wrong. Please try again." }), {
      status: 500,
      headers: { ...deps.cors, "Content-Type": "application/json" },
    });
  }
});