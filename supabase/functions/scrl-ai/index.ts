import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const DEFAULT_ORIGIN = "https://www.scrl.site";
const LEGACY_ORIGIN = "https://smisha2.github.io";
const CONFIGURED_ORIGIN = Deno.env.get("SCRL_AI_ALLOWED_ORIGIN") || "";
const ALLOWED_ORIGINS = new Set([DEFAULT_ORIGIN, LEGACY_ORIGIN, CONFIGURED_ORIGIN].filter(Boolean));
const ALLOWED_TASKS: Record<string, string> = {
  economy_report: "Подготовь краткий отчёт по экономике школьных учебных единиц.",
  moderation_overview: "Оцени общую нагрузку на модерацию и предложи безопасный порядок приоритизации.",
  moderation_queue: "Составь сводку очереди жалоб и споров, не вынося решений по отдельным людям.",
  help_metrics: "Оцени динамику школьной взаимопомощи по агрегированным показателям."
};
const METRIC_KEYS = [
  "participants", "activeParticipants", "blockedParticipants",
  "openReports", "postsReview", "listingsReview",
  "activeRequests", "activeOffers", "activeDeals", "openDisputes",
  "completedDeals", "scRlTotal", "vRubTotal", "coverageRatio",
  "targetRate", "currentRate", "feeRate", "burnedScRl"
] as const;

function responseJson(body: unknown, status: number, origin: string) {
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

Deno.serve(async (request: Request) => {
  const origin = request.headers.get("origin") || "";
  if (!origin || !ALLOWED_ORIGINS.has(origin)) {
    return responseJson({ error: "Источник запроса не разрешён." }, 403, DEFAULT_ORIGIN);
  }
  const allowedOrigin = origin;
  if (request.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": allowedOrigin,
        "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Vary": "Origin"
      }
    });
  }
  if (request.method !== "POST") {
    return responseJson({ error: "Метод не поддерживается." }, 405, allowedOrigin);
  }

  const authorization = request.headers.get("authorization") || "";
  const publishableKey = request.headers.get("apikey") || "";
  const projectUrl = Deno.env.get("SUPABASE_URL") || "";
  if (!authorization.startsWith("Bearer ") || !publishableKey || !projectUrl) {
    return responseJson({ error: "Не удалось проверить сессию ScRl." }, 401, allowedOrigin);
  }

  try {
    const adminCheck = await fetch(projectUrl.replace(/\/$/, "") + "/rest/v1/rpc/scrl_is_admin", {
      method: "POST",
      headers: {
        apikey: publishableKey,
        Authorization: authorization,
        "Content-Type": "application/json"
      },
      body: "{}"
    });
    if (!adminCheck.ok || await adminCheck.json().catch(() => false) !== true) {
      return responseJson({ error: "Функция доступна только администратору ScRl." }, 403, allowedOrigin);
    }

    const body = await request.json().catch(() => null);
    if (!body || typeof body !== "object" || !ALLOWED_TASKS[String(body.task || "")]) {
      return responseJson({ error: "Неизвестный тип отчёта." }, 400, allowedOrigin);
    }

    // Only whitelisted, bounded numeric aggregates cross this boundary.
    const incoming = body.metrics && typeof body.metrics === "object" ? body.metrics : {};
    const metrics: Record<string, number> = {};
    for (const key of METRIC_KEYS) {
      const value = Number(incoming[key]);
      if (Number.isFinite(value) && Math.abs(value) <= 1_000_000_000) {
        metrics[key] = Math.round(value * 10000) / 10000;
      }
    }

    if (Deno.env.get("SCRL_AI_ENABLED") !== "true" ||
        Deno.env.get("SCRL_AI_EXTERNAL_DATA_APPROVED") !== "true") {
      return responseJson({
        error: "Внешний ИИ не настроен или внешняя обработка не согласована. Используется локальный отчёт."
      }, 503, allowedOrigin);
    }

    const apiUrl = (Deno.env.get("SCRL_AI_API_URL") || "https://openrouter.ai/api/v1").replace(/\/+$/, "");
    const apiKey = Deno.env.get("SCRL_AI_API_KEY") || "";
    const model = Deno.env.get("SCRL_AI_MODEL") || "openrouter/free";
    if (!apiUrl || !apiKey || !model) {
      return responseJson({ error: "Не заданы параметры AI-провайдера в Edge Function Secrets." }, 503, allowedOrigin);
    }

    const providerResponse = await fetch(apiUrl + "/chat/completions", {
      method: "POST",
      headers: {
        Authorization: "Bearer " + apiKey,
        "Content-Type": "application/json",
        "HTTP-Referer": "https://www.scrl.site/",
        "X-Title": "ScRl Web"
      },
      body: JSON.stringify({
        model,
        temperature: 0.2,
        max_tokens: 800,
        messages: [
          {
            role: "system",
            content: "Ты аналитический помощник школьной платформы ScRl. Используй только переданные агрегированные числовые показатели. Не придумывай отсутствующие данные, не делай выводы о конкретных учениках и не предлагай автоматические блокировки или наказания. Пиши по-русски, кратко, структурированно и отмечай ограничения маленькой выборки. ScRl и V-RUB — учебные виртуальные единицы, не реальные деньги."
          },
          {
            role: "user",
            content: JSON.stringify({
              task: ALLOWED_TASKS[String(body.task)],
              metrics
            })
          }
        ]
      }),
      signal: AbortSignal.timeout(25000)
    });

    const providerPayload = await providerResponse.json().catch(() => null);
    if (!providerResponse.ok) {
      console.error("AI provider returned status", providerResponse.status);
      return responseJson({ error: "AI-провайдер временно недоступен. Проверь ключ, модель и лимиты." }, 502, allowedOrigin);
    }

    const content = providerPayload?.choices?.[0]?.message?.content;
    const answer = Array.isArray(content)
      ? content.map((part: any) => typeof part?.text === "string" ? part.text : "").join("\n").trim()
      : String(content || "").trim();
    if (!answer) {
      return responseJson({ error: "AI-провайдер не вернул текстовый ответ." }, 502, allowedOrigin);
    }

    return responseJson({ answer: answer.slice(0, 6000), model }, 200, allowedOrigin);
  } catch (error) {
    console.error("ScRl AI function failed:", error instanceof Error ? error.message : "unknown error");
    return responseJson({ error: "Не удалось получить ответ внешнего ИИ. Оставлен локальный отчёт." }, 502, allowedOrigin);
  }
});
