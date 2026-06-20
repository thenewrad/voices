import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const deepgramApiKey = Deno.env.get("DEEPGRAM_API_KEY")!;
const openaiApiKey = Deno.env.get("OPENAI_API_KEY")!;

Deno.serve(async (req: Request) => {
  try {
    const payload = await req.json();
    // Database webhook delivers { type, table, record, old_record }
    const record = payload.record as { id: string; audio_url: string };

    if (!record?.id || !record?.audio_url) {
      return respond({ error: "Missing record.id or record.audio_url" }, 400);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Attempt transcription + title generation; fall back to empty strings on failure
    let title = "";
    let transcript = "";

    try {
      // 1. Generate a short-lived signed URL for the audio file
      const { data: signed, error: signedError } = await supabase.storage
        .from("audio")
        .createSignedUrl(record.audio_url, 300);

      if (signedError || !signed?.signedUrl) {
        throw new Error(`Signed URL error: ${signedError?.message}`);
      }

      // 2. Download the audio
      const audioRes = await fetch(signed.signedUrl);
      if (!audioRes.ok) throw new Error(`Audio download failed: ${audioRes.status}`);
      const audioBuffer = await audioRes.arrayBuffer();

      // 3. Transcribe with Deepgram nova-2
      transcript = await transcribe(audioBuffer);

      // 4. Generate title with GPT-4o-mini (skip if transcript is empty)
      if (transcript.trim()) {
        title = await generateTitle(transcript);
      }
    } catch (err) {
      console.error("Transcription pipeline error:", err);
      // title and transcript stay as empty strings — clip still posts
    }

    // 5. Update the clips row
    const { error: updateError } = await supabase
      .from("clips")
      .update({ title, transcript })
      .eq("id", record.id);

    if (updateError) {
      console.error("DB update error:", updateError.message);
      return respond({ error: updateError.message }, 500);
    }

    return respond({ success: true, title, transcript_length: transcript.length });
  } catch (err) {
    console.error("Unhandled error:", err);
    return respond({ error: String(err) }, 500);
  }
});

// ---------------------------------------------------------------------------

async function transcribe(audioBuffer: ArrayBuffer): Promise<string> {
  const res = await fetch(
    "https://api.deepgram.com/v1/listen?model=nova-2&smart_format=true",
    {
      method: "POST",
      headers: {
        Authorization: `Token ${deepgramApiKey}`,
        "Content-Type": "audio/mp4",
      },
      body: audioBuffer,
    }
  );

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Deepgram ${res.status}: ${body}`);
  }

  const data = await res.json();
  return (
    data?.results?.channels?.[0]?.alternatives?.[0]?.transcript ?? ""
  );
}

async function generateTitle(transcript: string): Promise<string> {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${openaiApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      messages: [
        {
          role: "user",
          content:
            `Create a short 2-5 word title for this audio clip. Reply with ONLY the title.\n\nTranscript: ${transcript}`,
        },
      ],
      max_tokens: 20,
      temperature: 0.7,
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`OpenAI ${res.status}: ${body}`);
  }

  const data = await res.json();
  return data?.choices?.[0]?.message?.content?.trim() ?? "";
}

function respond(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
