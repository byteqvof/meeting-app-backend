import { requiredUuid } from "../_shared/validation.ts";

interface ActivityShareRow {
  id: string;
  title?: string | null;
  description?: string | null;
  city?: string | null;
  address_line?: string | null;
  starts_at?: string | null;
}

function htmlResponse(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=120",
    },
  });
}

function textResponse(message: string, status = 400): Response {
  return new Response(message, {
    status,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function activityIdFromRequest(req: Request): string {
  const url = new URL(req.url);
  const fromQuery = url.searchParams.get("activity_id") ?? url.searchParams.get(
    "id",
  );
  if (fromQuery) {
    return requiredUuid(fromQuery, "activity_id");
  }

  const segments = url.pathname.split("/").filter(Boolean);
  const maybeId = segments.at(-1);
  return requiredUuid(maybeId, "activity_id");
}

async function loadActivity(activityId: string): Promise<ActivityShareRow | null> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim();
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ??
    Deno.env.get("SUPABASE_ANON_KEY")?.trim();
  if (!supabaseUrl || !key) {
    throw new Error("Supabase share configuration is missing");
  }

  const endpoint = new URL("/rest/v1/activities", supabaseUrl);
  endpoint.searchParams.set(
    "select",
    "id,title,description,city,address_line,starts_at,status",
  );
  endpoint.searchParams.set("id", `eq.${activityId}`);
  endpoint.searchParams.set("status", "eq.published");
  endpoint.searchParams.set("limit", "1");

  const response = await fetch(endpoint, {
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      Accept: "application/json",
    },
  });

  if (!response.ok) {
    throw new Error(`Could not load activity: ${response.status}`);
  }

  const rows = await response.json() as ActivityShareRow[];
  return rows[0] ?? null;
}

function formatDate(value?: string | null): string {
  if (!value) {
    return "";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  return new Intl.DateTimeFormat("nl-NL", {
    weekday: "long",
    day: "numeric",
    month: "long",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

function sharePage({
  req,
  activityId,
  activity,
}: {
  req: Request;
  activityId: string;
  activity: ActivityShareRow | null;
}): string {
  const url = new URL(req.url);
  const canonicalUrl = url.toString();
  const appLink = `meetingsapp://activity/${encodeURIComponent(activityId)}`;
  const title = activity?.title?.trim() || "TOCH activiteit";
  const date = formatDate(activity?.starts_at);
  const place = activity?.address_line?.trim() || activity?.city?.trim() || "";
  const descriptionParts = [
    date,
    place,
    activity?.description?.trim(),
  ].filter((part) => part && part.length > 0);
  const description = descriptionParts.join(" · ") ||
    "Bekijk deze activiteit in TOCH en sluit aan.";

  return `<!doctype html>
<html lang="nl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(title)} | TOCH</title>
  <meta name="description" content="${escapeHtml(description)}">
  <meta property="og:type" content="website">
  <meta property="og:title" content="${escapeHtml(title)}">
  <meta property="og:description" content="${escapeHtml(description)}">
  <meta property="og:url" content="${escapeHtml(canonicalUrl)}">
  <meta name="twitter:card" content="summary">
  <meta name="theme-color" content="#145C43">
  <style>
    :root { color-scheme: light; font-family: Inter, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #145C43; color: #15221C; }
    main { width: min(420px, calc(100vw - 32px)); background: #F6F2EA; border-radius: 28px; padding: 28px; box-shadow: 0 24px 80px rgba(0,0,0,.28); }
    .brand { color: #145C43; font-weight: 900; font-size: 34px; letter-spacing: -0.02em; }
    .dot { color: #EA9B32; }
    h1 { margin: 28px 0 10px; font-size: 28px; line-height: 1.05; }
    p { margin: 0 0 22px; color: rgba(21,34,28,.72); font-size: 16px; line-height: 1.45; }
    a { display: inline-flex; justify-content: center; width: 100%; border-radius: 999px; padding: 16px 20px; background: #145C43; color: white; font-weight: 900; text-decoration: none; box-sizing: border-box; }
    small { display: block; margin-top: 14px; color: rgba(21,34,28,.52); text-align: center; }
  </style>
</head>
<body>
  <main>
    <div class="brand">toch<span class="dot">.</span></div>
    <h1>${escapeHtml(title)}</h1>
    <p>${escapeHtml(description)}</p>
    <a href="${escapeHtml(appLink)}">Open in TOCH</a>
    <small>Werkt de knop niet? Open TOCH en zoek deze activiteit.</small>
  </main>
  <script>
    const userAgent = navigator.userAgent.toLowerCase();
    const isPreviewBot = /bot|crawl|spider|whatsapp|facebookexternalhit|twitterbot|telegrambot|slackbot/.test(userAgent);
    if (!isPreviewBot) {
      setTimeout(() => { window.location.href = ${JSON.stringify(appLink)}; }, 500);
    }
  </script>
</body>
</html>`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204 });
  }
  if (req.method !== "GET" && req.method !== "HEAD") {
    return textResponse("Method not allowed", 405);
  }

  try {
    const activityId = activityIdFromRequest(req);
    const activity = await loadActivity(activityId);
    if (!activity) {
      return textResponse("Activity not found", 404);
    }

    const body = sharePage({ req, activityId, activity });
    return req.method === "HEAD" ? htmlResponse("", 200) : htmlResponse(body);
  } catch (error) {
    return textResponse(
      error instanceof Error ? error.message : "Invalid share link",
      400,
    );
  }
});
