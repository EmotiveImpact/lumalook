// @ts-nocheck
// Moved from api/founders.js (Vercel function) into a Next.js route; logic unchanged.
// POST /api/founders  Founding Creators application from /founders
//
// 1. Emails the full application to the team inbox, with reply-to set to the
//    applicant so a reply goes straight to them.
// 2. Saves the applicant as a Resend contact in the "Lumalook Founding
//    Creators" segment (if the segment is configured).
// 3. Sends the applicant one short confirmation with a copy of what they sent,
//    only the first time that address is seen.
//
// The skin-tone answer is optional and only accepted with its consent box
// ticked; it is used only to balance the test group (see privacy#founders).
//
// Environment (Vercel project settings):
//   RESEND_API_KEY                full-access key (already used by /api/waitlist)
//   FOUNDERS_NOTIFY_TO            inbox that receives applications; falls back to WAITLIST_REPLY_TO
//   RESEND_FOUNDERS_SEGMENT_ID    optional, the "Lumalook Founding Creators" segment
//   WAITLIST_FROM                 optional sender, defaults to "Lumalook <hello@lumalook.app>"

const API = "https://api.resend.com";
const EMAIL_RE = /^[^\s@<>()",;:]+@[^\s@<>()",;:]+\.[^\s@<>()",;:]{2,}$/;
const MAKES = ["Photos", "Video", "Beauty", "Fashion", "Music", "Weddings and events", "Street", "Everyday life"];

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

function rows(app) {
  return [
    ["Name", app.name],
    ["Email", app.email],
    ["Based in", app.location],
    ["iPhone", app.phone],
    ["Work", app.links],
    ["Makes", app.makes.join(", ") || "Not given"],
    ["Monk skin tone", app.monk ? app.monk + " of 10 (consent given)" : "Not given"],
    ["What apps get wrong", app.wrong],
    ["What they want from Lumalook", app.want || "Not given"],
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

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ ok: false, error: "method" });
  }
  const notifyTo = process.env.FOUNDERS_NOTIFY_TO || process.env.WAITLIST_REPLY_TO;
  if (!process.env.RESEND_API_KEY || !notifyTo) {
    return res.status(503).json({ ok: false, error: "unavailable" });
  }

  const body = await readBody(req);
  // Bots fill every field; people never see this one. Pretend it worked.
  if (body.website) return res.status(200).json({ ok: true });

  const makesIn = Array.isArray(body.makes) ? body.makes : body.makes ? [body.makes] : [];
  const consent = body.consent_tone === true || body.consent_tone === "yes";
  const monk = String(body.monk || "");
  const app = {
    name: oneLine(body.name, 80),
    email: oneLine(body.email, 254).toLowerCase(),
    location: oneLine(body.location, 80),
    phone: oneLine(body.phone, 60),
    links: oneLine(body.links, 300),
    makes: makesIn.map(String).filter((m) => MAKES.includes(m)),
    wrong: clean(body.wrong, 1500),
    want: clean(body.want, 1500),
    // Only keep a tone the applicant agreed we may use.
    monk: consent && /^(10|[1-9])$/.test(monk) ? monk : "",
  };
  const adult = body.adult === true || body.adult === "yes";

  if (!EMAIL_RE.test(app.email)) return res.status(400).json({ ok: false, error: "email" });
  if (!app.name || !app.location || !app.phone || !app.links || !app.wrong || !adult) {
    return res.status(400).json({ ok: false, error: "fields" });
  }

  const from = process.env.WAITLIST_FROM || "Lumalook <hello@lumalook.app>";
  const list = rows(app);

  try {
    // 1. The application itself, to the team. This is the one that must work.
    const teamIntro = "A new Founding Creators application from lumalook.app/founders. Reply to this email to answer the applicant directly.";
    const toTeam = await resend("/emails", "POST", {
      from,
      to: [notifyTo],
      reply_to: app.email,
      subject: "Founding Creators application: " + app.name,
      text: plain(teamIntro, list, "Sent by lumalook.app/founders"),
      html: shell("New Founding Creators application", esc(teamIntro), list, "Sent by lumalook.app/founders"),
    });
    if (!toTeam.ok) {
      console.error("founders: team email failed", toTeam.status, await toTeam.text());
      return res.status(502).json({ ok: false, error: "upstream" });
    }

    // 2. Keep the address as a Resend contact, in the Founding Creators
    //    segment when it is configured. A new contact also decides whether
    //    the applicant gets a copy: one copy per address, so the form can't
    //    be used to flood someone's inbox.
    const segment = process.env.RESEND_FOUNDERS_SEGMENT_ID;
    const parts = app.name.split(" ");
    const contact = {
      email: app.email,
      first_name: parts[0],
      unsubscribed: false,
    };
    if (parts.length > 1) contact.last_name = parts.slice(1).join(" ");
    if (segment) contact.segments = [{ id: segment }];
    const existing = await resend("/contacts/" + encodeURIComponent(app.email), "GET");
    let isNew = false;
    if (existing.ok) {
      if (segment) {
        const added = await resend("/contacts/" + encodeURIComponent(app.email) + "/segments/" + segment, "POST");
        if (!added.ok && added.status !== 409) console.error("founders: segment add failed", added.status, await added.text());
      }
    } else {
      const created = await resend("/contacts", "POST", contact);
      isNew = created.ok;
      if (!created.ok) console.error("founders: contact create failed", created.status, await created.text());
    }
    if (!isNew) return res.status(200).json({ ok: true });

    // 3. A copy for the applicant (best effort).
    const youIntro = "Thanks for applying to be a Lumalook Founding Creator. We read every application ourselves and pick the first group of about 30 when the next test build is ready. We'll email you either way.";
    const youFooter = "Want to change or withdraw your application, or have us delete it? Just reply to this email.<br>Lumalook, by Emotive Impact &middot; lumalook.app";
    const copy = {
      from,
      to: [app.email],
      reply_to: notifyTo,
      subject: "Your Lumalook Founding Creators application",
      text: plain(youIntro, list, "Want to change or withdraw your application, or have us delete it? Just reply to this email.\nLumalook, by Emotive Impact, https://lumalook.app"),
      html: shell("Your application is in.", esc(youIntro), list, youFooter),
    };
    const sent = await resend("/emails", "POST", copy);
    if (!sent.ok) console.error("founders: confirmation failed", sent.status, await sent.text());

    return res.status(200).json({ ok: true });
  } catch (err) {
    console.error("founders: error", err);
    return res.status(502).json({ ok: false, error: "upstream" });
  }
};
