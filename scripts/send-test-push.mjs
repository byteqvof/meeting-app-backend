#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";

const defaultSupabaseUrl = "https://pmnymluxikcmqehlbxlt.supabase.co";

function usage() {
  return `Usage:
  npm run push:test -- --profile-id <uuid> [--platform ios]
  npm run push:test -- --token <fcm-token> [--platform ios]

Options:
  --profile-id <uuid>    Load the newest enabled push token for this profile.
  --token <token>        Send directly to this FCM token.
  --platform <platform>  ios or android. Defaults to ios.
  --title <title>        Notification title. Defaults to "TOCH test push".
  --body <body>          Notification body.
  --activity-id <uuid>   Activity id used for app routing. Defaults to a random UUID.
  --validate-only        Ask FCM to validate without delivering.

Env:
  FCM_PROJECT_ID
  FCM_SERVICE_ACCOUNT_JSON or GOOGLE_APPLICATION_CREDENTIALS
  SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY when using --profile-id
`;
}

function parseArgs(argv) {
  const args = {
    platform: "ios",
    title: "TOCH test push",
    body: "Dit is een test push vanuit de TOCH backend.",
    activityId: crypto.randomUUID(),
    validateOnly: false,
  };

  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    const next = () => {
      const value = argv[++index];
      if (!value) {
        throw new Error(`Missing value for ${arg}`);
      }
      return value;
    };

    switch (arg) {
      case "--profile-id":
        args.profileId = next();
        break;
      case "--token":
        args.token = next();
        break;
      case "--platform":
        args.platform = next().toLowerCase();
        break;
      case "--title":
        args.title = next();
        break;
      case "--body":
        args.body = next();
        break;
      case "--activity-id":
        args.activityId = next();
        break;
      case "--validate-only":
        args.validateOnly = true;
        break;
      case "--help":
      case "-h":
        console.log(usage());
        process.exit(0);
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (args.platform !== "ios" && args.platform !== "android") {
    throw new Error("--platform must be ios or android");
  }
  if (!args.token && !args.profileId) {
    throw new Error("Pass --profile-id or --token");
  }
  return args;
}

function requiredEnv(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing env ${name}`);
  }
  return value;
}

function serviceAccountFromEnv() {
  const json = process.env.FCM_SERVICE_ACCOUNT_JSON?.trim();
  if (json) {
    return JSON.parse(json);
  }

  const path = process.env.GOOGLE_APPLICATION_CREDENTIALS?.trim();
  if (path) {
    return JSON.parse(fs.readFileSync(path, "utf8"));
  }

  throw new Error(
    "Missing FCM_SERVICE_ACCOUNT_JSON or GOOGLE_APPLICATION_CREDENTIALS",
  );
}

function base64Url(input) {
  return Buffer.from(input)
    .toString("base64")
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

async function createFcmAccessToken(serviceAccount) {
  const now = Math.floor(Date.now() / 1000);
  const tokenUri = serviceAccount.token_uri ?? "https://oauth2.googleapis.com/token";
  const header = { alg: "RS256", typ: "JWT" };
  const claim = {
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: tokenUri,
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${base64Url(JSON.stringify(header))}.${base64Url(
    JSON.stringify(claim),
  )}`;

  const signature = crypto
    .createSign("RSA-SHA256")
    .update(unsigned)
    .sign(serviceAccount.private_key);
  const assertion = `${unsigned}.${base64Url(signature)}`;

  const response = await fetch(tokenUri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });

  if (!response.ok) {
    throw new Error(`FCM access token failed: ${response.status} ${await response.text()}`);
  }

  const payload = await response.json();
  if (!payload.access_token) {
    throw new Error("FCM access token missing");
  }
  return payload.access_token;
}

async function latestTokenForProfile({ profileId, platform }) {
  const supabaseUrl = process.env.SUPABASE_URL?.trim() || defaultSupabaseUrl;
  const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
  const url = new URL("/rest/v1/device_push_tokens", supabaseUrl);
  url.searchParams.set("profile_id", `eq.${profileId}`);
  url.searchParams.set("platform", `eq.${platform}`);
  url.searchParams.set("enabled", "eq.true");
  url.searchParams.set("select", "token,platform,last_seen_at");
  url.searchParams.set("order", "last_seen_at.desc.nullslast");
  url.searchParams.set("limit", "1");

  const response = await fetch(url, {
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
    },
  });

  if (!response.ok) {
    throw new Error(`Token lookup failed: ${response.status} ${await response.text()}`);
  }

  const rows = await response.json();
  const row = rows[0];
  if (!row?.token) {
    throw new Error(`No enabled ${platform} token found for profile ${profileId}`);
  }
  return row.token;
}

function messageFor({ token, platform, title, body, activityId }) {
  const data = {
    type: "activity_chat",
    activity_id: activityId,
    message_id: crypto.randomUUID(),
    chat_title: title,
    chat_body: body,
    group_key: `activity_chat:${activityId}`,
  };

  const message = {
    token,
    notification: { title, body },
    data,
  };

  if (platform === "android") {
    message.android = {
      priority: "HIGH",
      notification: {
        channel_id: "activity_chat",
        click_action: "FLUTTER_NOTIFICATION_CLICK",
      },
    };
    return message;
  }

  message.apns = {
    headers: {
      "apns-priority": "10",
    },
    payload: {
      aps: {
        alert: { title, body },
        sound: "default",
        "thread-id": activityId,
      },
    },
  };
  return message;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const projectId = requiredEnv("FCM_PROJECT_ID");
  const serviceAccount = serviceAccountFromEnv();
  const token = args.token ?? await latestTokenForProfile(args);
  const accessToken = await createFcmAccessToken(serviceAccount);
  const endpoint = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
  const requestBody = {
    validate_only: args.validateOnly,
    message: messageFor({
      token,
      platform: args.platform,
      title: args.title,
      body: args.body,
      activityId: args.activityId,
    }),
  };

  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(requestBody),
  });

  const responseText = await response.text();
  if (!response.ok) {
    console.error(`FCM send failed: ${response.status}`);
    console.error(responseText);
    process.exit(1);
  }

  console.log(args.validateOnly ? "FCM validation succeeded." : "Push sent.");
  console.log(responseText);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  console.error("");
  console.error(usage());
  process.exit(1);
});
