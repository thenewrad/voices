// Checks an uploaded image (profile avatar, channel icon) against Google
// Cloud Vision's SafeSearch Detection before the client is allowed to save
// it. Called synchronously by both clients (Swift, Expo) from their upload
// flows — reject here means the image is never written to storage.
//
// Setup: see docs/google-vision-moderation-setup.md in the Expo repo for
// getting a Vision API key and deploying/configuring this function.

const visionApiKey = Deno.env.get("GOOGLE_VISION_API_KEY");

// SafeSearch likelihood enum, ranked so a numeric threshold comparison works.
const LIKELIHOOD_RANK: Record<string, number> = {
  UNKNOWN: 0,
  VERY_UNLIKELY: 1,
  UNLIKELY: 2,
  POSSIBLE: 3,
  LIKELY: 4,
  VERY_LIKELY: 5,
};

// Reject once a category's likelihood reaches this rank. Racy is held to a
// looser bar than adult/violence — "possible racy" (e.g. a swimsuit photo)
// is normal profile-photo content; "likely/very likely" is not.
const REJECT_THRESHOLDS: Record<string, number> = {
  adult: LIKELIHOOD_RANK.LIKELY,
  violence: LIKELIHOOD_RANK.LIKELY,
  racy: LIKELIHOOD_RANK.VERY_LIKELY,
};

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return respond({ error: "Method not allowed" }, 405);

  if (!visionApiKey) {
    console.error("moderate-image: GOOGLE_VISION_API_KEY is not set");
    return respond({ error: "Moderation is not configured." }, 500);
  }

  try {
    const { imageBase64 } = await req.json();
    if (!imageBase64 || typeof imageBase64 !== "string") {
      return respond({ error: "Missing imageBase64" }, 400);
    }

    const visionRes = await fetch(
      `https://vision.googleapis.com/v1/images:annotate?key=${visionApiKey}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          requests: [
            {
              image: { content: imageBase64 },
              features: [{ type: "SAFE_SEARCH_DETECTION" }],
            },
          ],
        }),
      },
    );

    if (!visionRes.ok) {
      console.error(`Vision API ${visionRes.status}: ${await visionRes.text()}`);
      return respond({ error: "Moderation check failed." }, 502);
    }

    const data = await visionRes.json();
    const result = data?.responses?.[0];

    if (result?.error) {
      console.error("Vision API returned an error:", result.error);
      return respond({ error: "Moderation check failed." }, 502);
    }

    const annotation = result?.safeSearchAnnotation;
    if (!annotation) {
      console.error("Vision API returned no safeSearchAnnotation:", JSON.stringify(data));
      return respond({ error: "Moderation check returned no result." }, 502);
    }

    const reasons = Object.entries(REJECT_THRESHOLDS)
      .filter(([category, threshold]) => (LIKELIHOOD_RANK[annotation[category]] ?? 0) >= threshold)
      .map(([category]) => category);

    return respond({ allowed: reasons.length === 0, reasons });
  } catch (err) {
    console.error("moderate-image error:", err);
    return respond({ error: String(err) }, 500);
  }
});

function respond(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
