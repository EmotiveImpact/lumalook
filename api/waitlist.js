// POST /api/waitlist  { email, website }  (website is a honeypot that people never see)
//
// Saves the address as a Resend contact in the Lumalook waitlist segment and
// sends one short confirmation email. A repeat signup is added to the segment
// again but gets no second email, so the form cannot be used to flood someone.
//
// Environment (Vercel project settings):
//   RESEND_API_KEY              full-access key (contacts need more than sending access)
//   RESEND_WAITLIST_SEGMENT_ID  the "Lumalook waitlist" segment
//   WAITLIST_FROM               optional, defaults to "Lumalook <hello@lumalook.app>"
//   WAITLIST_REPLY_TO           optional reply-to address

const API = "https://api.resend.com";
const EMAIL_RE = /^[^\s@<>()",;:]+@[^\s@<>()",;:]+\.[^\s@<>()",;:]{2,}$/;

function resend(path, method, body) {
  return fetch(API + path, {
    method,
    headers: {
      Authorization: "Bearer " + process.env.RESEND_API_KEY,
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
}

function confirmation(to) {
  const text = [
    "You're on the Lumalook waitlist.",
    "",
    "Lumalook is a camera, grade room and video editor for iPhone, with film looks tuned on deep skin first.",
    "We'll email you once, on launch day, with the App Store link. Nothing else in between.",
    "",
    "Want everything for good? Lifetime is $79.99 once on the web: every look and every pack, now and in future.",
    "https://lumalook.app/#pricing",
    "",
    "Didn't sign up? Ignore this email and you won't hear from us again.",
    "",
    "Lumalook, by Emotive Impact",
    "https://lumalook.app",
  ].join("\n");

  const html = `<!doctype html><html lang="en-GB"><body style="margin:0;background:#08090a;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#08090a;">
<tr><td align="center" style="padding:40px 20px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;font-family:Inter,-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:#f7f8f8;">
<tr><td style="font-size:15px;font-weight:700;letter-spacing:-0.02em;padding-bottom:36px;"><span style="display:inline-block;width:9px;height:9px;border-radius:50%;background:#ffc53d;margin-right:8px;vertical-align:1px;"></span>lumalook</td></tr>
<tr><td style="font-size:30px;line-height:1.15;font-weight:650;letter-spacing:-0.04em;padding-bottom:18px;">You're on the list.</td></tr>
<tr><td style="font-size:15.5px;line-height:1.6;color:#a3a6ad;padding-bottom:16px;">Lumalook is a camera, grade room and video editor for iPhone, with film looks tuned on deep skin first.</td></tr>
<tr><td style="font-size:15.5px;line-height:1.6;color:#a3a6ad;padding-bottom:30px;">We'll email you once, on launch day, with the App Store link. Nothing else in between.</td></tr>
<tr><td style="background:#121316;border-radius:14px;padding:22px 22px 24px;">
<div style="font-size:13px;font-weight:650;color:#ffc53d;padding-bottom:6px;">Lifetime, $79.99 once</div>
<div style="font-size:15px;line-height:1.55;color:#f7f8f8;padding-bottom:16px;">Every look and every pack, now and in future. No subscription.</div>
<a href="https://lumalook.app/#pricing" style="display:inline-block;background:#ffc53d;color:#141006;font-size:14.5px;font-weight:650;text-decoration:none;padding:12px 18px;border-radius:10px;">See Lifetime</a>
</td></tr>
<tr><td style="font-size:13px;line-height:1.6;color:#6e727a;padding-top:30px;">Didn't sign up? Ignore this email and you won't hear from us again.<br>Lumalook, by Emotive Impact &middot; <a href="https://lumalook.app" style="color:#a3a6ad;">lumalook.app</a></td></tr>
</table></td></tr></table></body></html>`;

  const msg = {
    from: process.env.WAITLIST_FROM || "Lumalook <hello@lumalook.app>",
    to: [to],
    subject: "You're on the Lumalook waitlist",
    text,
    html,
  };
  if (process.env.WAITLIST_REPLY_TO) msg.reply_to = process.env.WAITLIST_REPLY_TO;
  return resend("/emails", "POST", msg);
}

async function readBody(req) {
  if (req.body && typeof req.body === "object") return req.body;
  if (typeof req.body === "string") {
    try { return JSON.parse(req.body); } catch (e) { return {}; }
  }
  return {};
}

module.exports = async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ ok: false, error: "method" });
  }
  if (!process.env.RESEND_API_KEY || !process.env.RESEND_WAITLIST_SEGMENT_ID) {
    return res.status(503).json({ ok: false, error: "unavailable" });
  }

  const body = await readBody(req);
  // Bots fill every field; people never see this one. Pretend it worked.
  if (body.website) return res.status(200).json({ ok: true });

  const email = String(body.email || "").trim().toLowerCase();
  if (email.length > 254 || !EMAIL_RE.test(email)) {
    return res.status(400).json({ ok: false, error: "email" });
  }

  const segment = process.env.RESEND_WAITLIST_SEGMENT_ID;
  try {
    // Already a contact: make sure they are in the segment, and send nothing.
    const existing = await resend("/contacts/" + encodeURIComponent(email), "GET");
    if (existing.ok) {
      const added = await resend(
        "/contacts/" + encodeURIComponent(email) + "/segments/" + segment,
        "POST"
      );
      if (!added.ok && added.status !== 409) console.error("waitlist: segment add failed", added.status, await added.text());
      return res.status(200).json({ ok: true, already: true });
    }

    const created = await resend("/contacts", "POST", {
      email,
      unsubscribed: false,
      segments: [{ id: segment }],
    });
    if (!created.ok) {
      console.error("waitlist: contact create failed", created.status, await created.text());
      return res.status(502).json({ ok: false, error: "upstream" });
    }

    const sent = await confirmation(email);
    if (!sent.ok) console.error("waitlist: confirmation failed", sent.status, await sent.text());
    return res.status(200).json({ ok: true });
  } catch (err) {
    console.error("waitlist: error", err);
    return res.status(502).json({ ok: false, error: "upstream" });
  }
};
