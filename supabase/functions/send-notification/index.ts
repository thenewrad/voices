/**
 * send-notification
 * Sends a visible APNs push notification to a specific user.
 *
 * POST body:
 *   recipient_user_id  – UUID of the user to notify
 *   title              – Notification title
 *   body               – Notification body text
 *   data               – Optional key/value payload (object). The iOS app reads
 *                        `data.type` to deep-link a notification tap into the
 *                        Activity center: "direct_message" opens the Messages
 *                        tab, "reply"/"reply_to_reply" opens the Replies tab.
 *
 * Required secrets (set via `npx supabase secrets set`):
 *   APNS_KEY_ID       – 10-char key ID from Apple Developer portal
 *   APNS_TEAM_ID      – 10-char team ID from Apple Developer portal
 *   APNS_PRIVATE_KEY  – Contents of the .p8 file (including header/footer)
 *   APNS_BUNDLE_ID    – e.g. com.yourcompany.zeitvox
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SignJWT, importPKCS8 } from "https://deno.land/x/jose@v5.2.0/index.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const apnsKeyId = Deno.env.get("APNS_KEY_ID")!;
const apnsTeamId = Deno.env.get("APNS_TEAM_ID")!;
const apnsPrivateKey = Deno.env.get("APNS_PRIVATE_KEY")!;
const apnsBundleId = Deno.env.get("APNS_BUNDLE_ID")!;
// Set APNS_SANDBOX=true for development/TestFlight builds; omit or set false for App Store
const apnsSandbox = Deno.env.get("APNS_SANDBOX") === "true";
const apnsHost = apnsSandbox
  ? "api.sandbox.push.apple.com"
  : "api.push.apple.com";;

interface NotificationRequest {
  recipient_user_id: string;
  title: string;
  body: string;
  data?: Record<string, string>;
}

Deno.serve(async (req: Request) => {
  try {
    const payload: NotificationRequest = await req.json();
    const { recipient_user_id, title, body, data } = payload;

    if (!recipient_user_id || !title || !body) {
      return respond({ error: "Missing required fields" }, 400);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Fetch all APNs tokens for this user
    const { data: tokens, error: tokenErr } = await supabase
      .from("device_tokens")
      .select("token")
      .eq("user_id", recipient_user_id)
      .eq("platform", "apns");

    if (tokenErr) {
      console.error("Token fetch error:", tokenErr);
      return respond({ error: "Failed to fetch tokens" }, 500);
    }

    if (!tokens?.length) {
      return respond({ sent: 0, reason: "no_tokens" });
    }

    const apnsJwt = await makeApnsJwt();

    const results = await Promise.allSettled(
      tokens.map((t: { token: string }) =>
        sendAlertPush(t.token, apnsJwt, title, body, data ?? {})
      )
    );

    const sent = results.filter((r) => r.status === "fulfilled").length;
const errors = results
  .filter((r) => r.status === "rejected")
  .map((r) => (r as PromiseRejectedResult).reason?.message ?? String(r));
return respond({ sent, failed: results.length - sent, errors });
  } catch (err) {
    console.error("send-notification error:", err);
    return respond({ error: String(err) }, 500);
  }
});

// ---------------------------------------------------------------------------

async function makeApnsJwt(): Promise<string> {
  const key = await importPKCS8(apnsPrivateKey, "ES256");
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: apnsKeyId })
    .setIssuedAt()
    .setIssuer(apnsTeamId)
    .sign(key);
}

async function sendAlertPush(
  deviceToken: string,
  jwt: string,
  title: string,
  body: string,
  data: Record<string, string>
): Promise<void> {
  const url = `https://${apnsHost}/3/device/${deviceToken}`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": apnsBundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: {
        alert: { title, body },
        sound: "default",
        badge: 1,
      },
      ...data,
    }),
  });

  if (!res.ok) {
    const responseBody = await res.text();
    console.error("APNs rejected token:", deviceToken.slice(0,10), "status:", res.status, "body:", responseBody);

    // 400 BadDeviceToken / 410 Unregistered — token is invalid or expired, remove it
    if (res.status === 400 || res.status === 410) {
      const supabase = createClient(supabaseUrl, supabaseServiceKey);
      const { error: deleteErr } = await supabase
        .from("device_tokens")
        .delete()
        .eq("token", deviceToken);
      if (deleteErr) {
        console.error("Failed to delete bad token:", deleteErr.message);
      } else {
        console.log("Deleted stale token:", deviceToken.slice(0, 10));
      }
    }

    throw new Error(`APNs ${res.status}: ${responseBody}`);
  }
}

function respond(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
