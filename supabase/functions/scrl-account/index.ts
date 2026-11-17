import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const DEFAULT_ORIGIN = "https://smisha2.github.io";
const ALLOWED_ORIGINS = new Set([DEFAULT_ORIGIN, "http://localhost:3000", "http://127.0.0.1:5500"]);

function response(body: unknown, status: number, origin: string) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Access-Control-Allow-Origin": origin,
      "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Vary": "Origin",
      "Cache-Control": "no-store"
    }
  });
}

function secret(name: string, dictionaryName: string) {
  const direct = Deno.env.get(name) || "";
  if (direct) return direct;
  try {
    const values = JSON.parse(Deno.env.get(dictionaryName) || "{}");
    return typeof values.default === "string" ? values.default : "";
  } catch {
    return "";
  }
}

Deno.serve(async (req: Request) => {
  const requestOrigin = req.headers.get("origin") || DEFAULT_ORIGIN;
  const origin = ALLOWED_ORIGINS.has(requestOrigin) ? requestOrigin : DEFAULT_ORIGIN;

  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": origin,
        "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Vary": "Origin"
      }
    });
  }
  if (req.method !== "POST") return response({ error: "Method not allowed." }, 405, origin);
  if (!ALLOWED_ORIGINS.has(requestOrigin)) return response({ error: "Origin not allowed." }, 403, origin);

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.replace(/^Bearer\s+/i, "").trim();
    if (!token || token === authHeader) return response({ error: "Требуется войти в аккаунт." }, 401, origin);

    let payload: Record<string, unknown> = {};
    try { payload = await req.json(); } catch { return response({ error: "Некорректный запрос." }, 400, origin); }
    if (payload.action === "delete_account") {
      if (payload.confirmation !== "УДАЛИТЬ") {
        return response({ error: "Подтверди удаление аккаунта." }, 400, origin);
      }
    } else if (payload.action === "delete_post") {
      const postId = typeof payload.post_id === "string" ? payload.post_id : "";
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(postId)) {
        return response({ error: "Некорректный идентификатор публикации." }, 400, origin);
      }
    } else {
      return response({ error: "Неизвестное действие." }, 400, origin);
    }

    const url = (Deno.env.get("SUPABASE_URL") || "").replace(/\/+$/, "");
    const publishableKey = secret("SUPABASE_ANON_KEY", "SUPABASE_PUBLISHABLE_KEYS");
    const serviceKey = secret("SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_SECRET_KEYS");
    if (!url || !publishableKey || !serviceKey) {
      return response({ error: "Сервис удаления пока не настроен. Обратись к администратору." }, 503, origin);
    }

    const userClient = createClient(url, publishableKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: "Bearer " + token } }
    });
    const { data: userData, error: userError } = await userClient.auth.getUser(token);
    if (userError || !userData.user) return response({ error: "Сессия устарела. Войди снова." }, 401, origin);

    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });

    if (payload.action === "delete_post") {
      const { error } = await admin.rpc("scrl_delete_own_post", {
        p_user: userData.user.id,
        p_post: payload.post_id as string
      });
      if (error) {
        return response({ error: error.message || "Не удалось удалить публикацию." }, 409, origin);
      }
      return response({ success: true }, 200, origin);
    }

    // This RPC anonymizes user-authored data and keeps profile IDs referenced by
    // historical financial rows. It also refuses deletion while holds or active
    // deals, market orders, or auctions exist.
    const { error: cleanupError } = await admin.rpc("scrl_delete_account", { p_user: userData.user.id });
    if (cleanupError) {
      return response({ error: cleanupError.message || "Перед удалением нужно завершить активные операции." }, 409, origin);
    }

    // Delete the Auth identity only after the financial/history records are safe.
    const { error: deleteError } = await admin.auth.admin.deleteUser(userData.user.id);
    if (deleteError) {
      return response({
        error: "Личные данные обезличены, но Auth не завершил удаление. Повтори попытку или обратись к администратору.",
        anonymized: true
      }, 502, origin);
    }

    return response({ success: true }, 200, origin);
  } catch (error) {
    console.error("scrl-account deletion failed:", error instanceof Error ? error.message : "unknown");
    return response({ error: "Не удалось удалить аккаунт. Попробуй ещё раз." }, 500, origin);
  }
});
