// POST /api/partners  Partner enquiry from /partners
//
// Emails the enquiry to the team inbox with reply-to set to the sender, so a
// reply goes straight to them. Nothing is stored and no contact is created:
// the enquiry lives only in the team inbox (see privacy#partners).
//
// Environment (Vercel project settings, the same ones /api/founders uses):
//   RESEND_API_KEY        full-access key
//   PARTNERS_NOTIFY_TO    inbox for enquiries; falls back to FOUNDERS_NOTIFY_TO, then WAITLIST_REPLY_TO
//   WAITLIST_FROM         optional sender, defaults to "Lumalook <hello@lumalook.app>"

const API = "https://api.resend.com";
const EMAIL_RE = /^[^\s@<>()",;:]+@[^\s@<>()",;:]+\.[^\s@<>()",;:]{2,}$/;
const TOPICS = ["Sponsorship", "Brand partnership", "Community or education", "Press", "Something else"];

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

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function clean(v, max) {
  return String(v == null ? "" : v).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "").trim().slice(0, max);
}

function oneLine(v, max) {
  return clean(v, max).replace(/\s+/g, " ");
}

async function readBody(req) {
  let body = req.body;
  if (typeof body === "string") {
    try { body = JSON.parse(body); } catch (e) {
      body = Object.fromEntries(new URLSearchParams(body));
    }
  }
  return body && typeof body === "object" ? body : {};
}

function rows(e) {
  return [
    ["Name", e.name],
    ["Email", e.email],
    ["Organisation", e.org],
    ["Website", e.site || "Not given"],
    ["About", e.topic || "Not given"],
    ["Timing", e.timing || "Not given"],
    ["Message", e.message],
  ];
}

function table(list) {
  return list.map(([k, v]) =>
    `<tr><td style="padding:10px 14px 10px 0;vertical-align:top;color:#6e727a;font-size:13px;white-space:nowrap;">${esc(k)}</td>` +
    `<td style="padding:10px 0;vertical-align:top;color:#f7f8f8;font-size:14.5px;line-height:1.55;white-space:pre-wrap;">${esc(v)}</td></tr>`
  ).join("");
}

function shell(title, intro, list, footer) {
  return `<!doctype html><html lang="en-GB"><body style="margin:0;background:#08090a;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#08090a;"><tr><td align="center" style="padding:36px 18px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;font-family:Inter,-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:#f7f8f8;">
<tr><td style="font-size:15px;font-weight:700;letter-spacing:-0.02em;padding-bottom:30px;"><span style="display:inline-block;width:9px;height:9px;border-radius:50%;background:#ffc53d;margin-right:8px;vertical-align:1px;"></span>lumalook</td></tr>
<tr><td style="font-size:26px;line-height:1.2;font-weight:650;letter-spacing:-0.035em;padding-bottom:14px;">${esc(title)}</td></tr>
<tr><td style="font-size:15px;line-height:1.6;color:#a3a6ad;padding-bottom:22px;">${intro}</td></tr>
<tr><td style="background:#121316;border-radius:14px;padding:8px 20px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0">${table(list)}</table></td></tr>
<tr><td style="font-size:13px;line-height:1.6;color:#6e727a;padding-top:26px;">${footer}</td></tr>
</table></td></tr></table></body></html>`;
}

function plain(intro, list, footer) {
  return [intro, "", ...list.map(([k, v]) => k + ": " + v), "", footer].join("\n");
}

module.exports = async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ ok: false, error: "method" });
  }
  const notifyTo = process.env.PARTNERS_NOTIFY_TO || process.env.FOUNDERS_NOTIFY_TO || process.env.WAITLIST_REPLY_TO;
  if (!process.env.RESEND_API_KEY || !notifyTo) {
    return res.status(503).json({ ok: false, error: "unavailable" });
  }

  const body = await readBody(req);
  // Bots fill every field; people never see this one. Pretend it worked.
  if (body.website) return res.status(200).json({ ok: true });

  const topic = oneLine(body.topic, 40);
  const e = {
    name: oneLine(body.name, 80),
    email: oneLine(body.email, 254).toLowerCase(),
    org: oneLine(body.org, 120),
    site: oneLine(body.site, 200),
    topic: TOPICS.includes(topic) ? topic : "",
    message: clean(body.message, 3000),
    timing: oneLine(body.timing, 120),
  };
  if (!EMAIL_RE.test(e.email)) return res.status(400).json({ ok: false, error: "email" });
  if (!e.name || !e.org || !e.message) return res.status(400).json({ ok: false, error: "fields" });

  const from = process.env.WAITLIST_FROM || "Lumalook <hello@lumalook.app>";
  const list = rows(e);
  const intro = "A new partner enquiry from lumalook.app/partners. Reply to this email to answer them directly.";
  try {
    const sent = await resend("/emails", "POST", {
      from,
      to: [notifyTo],
      reply_to: e.email,
      subject: "Partner enquiry" + (e.topic ? " (" + e.topic + ")" : "") + ": " + e.org,
      text: plain(intro, list, "Sent by lumalook.app/partners"),
      html: shell("New partner enquiry", esc(intro), list, "Sent by lumalook.app/partners"),
    });
    if (!sent.ok) {
      console.error("partners: team email failed", sent.status, await sent.text());
      return res.status(502).json({ ok: false, error: "upstream" });
    }
    return res.status(200).json({ ok: true });
  } catch (err) {
    console.error("partners: error", err);
    return res.status(502).json({ ok: false, error: "upstream" });
  }
};
