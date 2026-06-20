/**
 * notify-followers
 * Triggered via a Supabase database webhook on INSERT to the clips table.
 * Sends a silent APNs push to every follower so their feed background-refreshes.
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

Deno.serve(async (req: Request) => {
  try {
    const { record } = await req.json();
    const posterId: string = record?.user_id;
    if (!posterId) return respond({ error: "Missing user_id" }, 400);

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // 1. Find all followers of the poster
    const { data: follows, error: followErr } = await supabase
      .from("follows")
      .select("follower_id")
      .eq("following_id", posterId);

    if (followErr || !follows?.length) {
      return respond({ sent: 0 });
    }

    const followerIds = follows.map((f: { follower_id: string }) => f.follower_id);

    // 2. Fetch their APNs device tokens
    const { data: tokens, error: tokenErr } = await supabase
      .from("device_tokens")
      .select("token")
      .in("user_id", followerIds)
      .eq("platform", "apns");

    if (tokenErr || !tokens?.length) {
      return respond({ sent: 0 });
    }

    // 3. Generate APNs JWT (valid for 1 hour, reused across all sends)
    const apnsJwt = await makeApnsJwt();

    // 4. Send a silent push to each token
    const results = await Promise.allSettled(
      tokens.map((t: { token: string }) => sendSilentPush(t.token, apnsJwt))
    );

    const sent = results.filter((r) => r.status === "fulfilled").length;
    const failed = results.length - sent;
    return respond({ sent, failed });
  } catch (err) {
    console.error("notify-followers error:", err);
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

async function sendSilentPush(deviceToken: string, jwt: string): Promise<void> {
  // Use APNs production endpoint; swap for api.sandbox.push.apple.com during dev
  const url = `https://api.push.apple.com/3/device/${deviceToken}`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": apnsBundleId,
      "apns-push-type": "background",
      "apns-priority": "5",       // 5 = normal priority, required for background
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: {
        "content-available": 1,   // silent push — no alert shown
      },
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`APNs ${res.status}: ${body}`);
  }
}

function respond(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
