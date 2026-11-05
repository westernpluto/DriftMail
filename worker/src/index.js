// DriftMail relay — a Cloudflare Worker that runs on the free plan.
//
// Every minute a Cron Trigger signs in to each of your IMAP inboxes, catches up
// on anything new, then keeps the connection open in IMAP IDLE for ~50 seconds
// so the mail server tells us the instant a message arrives. The next minute's
// run takes over, so notifications arrive within seconds, around the clock.
// Pushes go through ntfy (free) or Apple Push Notification service.
//
// Free-plan budget: 1 cron per minute (15 min wall time allowed, waiting does
// not count as CPU), ~3 KV reads per run, and KV writes only when something
// changes (new mail, an error appearing or clearing).

import { connect } from "cloudflare:sockets";

const CONFIG_KEY = "config";
const STATE_KEY = "state";
const OWNER_KEY = "owner";
const STATUS_KEY = "status";
const APNS_JWT_KEY = "apns-jwt";
const MAX_NOTIFICATIONS_PER_ACCOUNT = 5;
const DEFAULT_IDLE_SECONDS = 50;
const PAIR_FAILS_KEY = "pair-fails";
const MAX_PAIR_FAILS = 10;                 // wrong pairing codes allowed…
const PAIR_LOCKOUT_MS = 60 * 60 * 1000;    // …per hour before pairing locks   // stay connected this long per one-minute run

export default {
  async fetch(request, env, ctx) {
    try {
      return await route(request, env, ctx);
    } catch (error) {
      return json({ error: String(error?.message || error) }, 500);
    }
  },

  async scheduled(event, env, ctx) {
    const configured = Number(env.IDLE_SECONDS);
    const seconds = Number.isFinite(configured) && env.IDLE_SECONDS !== undefined ? configured : DEFAULT_IDLE_SECONDS;
    const idleUntil = seconds > 0 ? Date.now() + Math.min(seconds, 55) * 1000 : 0;
    await checkAll(env, { idleUntil });
  },
};

// ---------------------------------------------------------------------------
// HTTP API used by the app
// ---------------------------------------------------------------------------

async function route(request, env) {
  const url = new URL(request.url);
  if (url.pathname === "/" && request.method === "GET") {
    return new Response("DriftMail relay is running.\n", { headers: { "content-type": "text/plain" } });
  }
  if (!url.pathname.startsWith("/v1/")) return json({ error: "Not found" }, 404);
  if (!env.DRIFT) return json({ error: "KV namespace binding DRIFT is missing." }, 500);

  const auth = await authorize(request, env, url.pathname === "/v1/sync" && request.method === "POST");
  if (!auth.ok) return json({ error: auth.error }, auth.status || 401);

  if (url.pathname === "/v1/sync" && request.method === "POST") {
    const body = await request.json();
    const delivery = validateDelivery(body.delivery);
    // Keep the push environment learned from Apple (see deliver()) while the
    // device token is unchanged: re-signed builds can't tell which environment
    // they were signed for, so the phone's own guess would undo it on every sync.
    if (delivery.type === "apns") {
      const previous = (await loadConfig(env))?.delivery;
      if (previous?.type === "apns" && previous.token === delivery.token && previous.learnedEnvironment) {
        delivery.environment = previous.learnedEnvironment;
        delivery.learnedEnvironment = previous.learnedEnvironment;
      }
    }
    const accounts = Array.isArray(body.accounts) ? body.accounts : [];
    if (accounts.length > 10) return json({ error: "At most 10 accounts are supported." }, 400);
    const stored = [];
    for (const a of accounts) {
      if (!a.id || !a.host || !a.username || !a.password) continue;
      stored.push({
        id: String(a.id),
        email: String(a.email || a.username),
        host: String(a.host),
        port: Number(a.port) || 993,
        username: String(a.username),
        password: await encrypt(env, String(a.password)),
      });
    }
    // End-to-end encryption key for native notifications (generated on the phone).
    let e2eKey = null;
    if (body.e2eKey) {
      const raw = fromB64(String(body.e2eKey));
      if (raw.length !== 32) return json({ error: "Invalid notification key." }, 400);
      e2eKey = await encrypt(env, String(body.e2eKey));
    }
    const config = { delivery, showPreviews: body.showPreviews !== false, accounts: stored, e2eKey, updated: new Date().toISOString() };
    await env.DRIFT.put(CONFIG_KEY, JSON.stringify(config));
    // Take a baseline right away so existing mail never triggers notifications.
    const state = await checkAll(env, { baselineOnly: true });
    return json({ ok: true, accounts: stored.length, state: Object.keys(state).length });
  }

  if (url.pathname === "/v1/sync" && request.method === "DELETE") {
    await env.DRIFT.delete(CONFIG_KEY);
    await env.DRIFT.delete(STATE_KEY);
    await env.DRIFT.delete(STATUS_KEY);
    return json({ ok: true });
  }

  if (url.pathname === "/v1/test" && request.method === "POST") {
    const config = await loadConfig(env);
    if (!config) return json({ error: "Connect your accounts first." }, 400);
    await deliver(env, config, {
      title: "DriftMail is connected",
      body: "You'll get a notification like this when new mail arrives.",
      accountId: null,
      uid: null,
      test: true,
    });
    return json({ ok: true });
  }

  if (url.pathname === "/v1/status" && request.method === "GET") {
    const config = await loadConfig(env);
    const status = (await env.DRIFT.get(STATUS_KEY, "json")) || {};
    return json({
      configured: !!config,
      delivery: config?.delivery?.type ?? null,
      lastRun: status.lastRun ?? null,
      accounts: (config?.accounts || []).map((a) => ({
        id: a.id,
        email: a.email,
        lastError: status.errors?.[a.id] ?? null,
        lastChecked: status.lastRun ?? null,
      })),
    });
  }

  return json({ error: "Not found" }, 404);
}

/// Every phone sends a random token it generated (kept in its Keychain).
/// The relay remembers the SHA-256 of its owner's token. A phone becomes the
/// owner only by also presenting the pairing code, which is a Worker secret
/// (PAIRING_CODE) that only you know. A guessed or leaked relay address is
/// therefore useless. The same code lets you re-pair a new or reinstalled phone.
/// If ADMIN_TOKEN is set it replaces all of this with a fixed shared token.
async function authorize(request, env, mayClaim) {
  const header = request.headers.get("authorization") || "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (token.length < 20) return { ok: false, error: "Missing or short token." };
  if (env.ADMIN_TOKEN) {
    return timingSafeEqual(token, env.ADMIN_TOKEN) ? { ok: true } : { ok: false, error: "Wrong token." };
  }
  const hash = await sha256Hex(token);
  const owner = await env.DRIFT.get(OWNER_KEY);
  if (owner && timingSafeEqual(owner, hash)) return { ok: true };

  // Not the owner (or no owner yet): pairing requires the secret code.
  if (!mayClaim) {
    return { ok: false, error: owner ? "This phone isn't paired with the relay. Enter the pairing code and tap Connect." : "This relay isn't paired yet. Enter the pairing code and tap Connect." };
  }
  if (!env.PAIRING_CODE) {
    return { ok: false, error: "The relay has no pairing code. Add the RELAY_PAIRING_CODE secret and run the deploy workflow again." };
  }
  // Brute-force protection: after 10 wrong codes in an hour, pairing locks for the
  // rest of that hour. While locked nothing is written, so KV writes stay bounded.
  const now = Date.now();
  let fails = (await env.DRIFT.get(PAIR_FAILS_KEY, "json")) || { count: 0, since: now };
  if (now - fails.since > PAIR_LOCKOUT_MS) fails = { count: 0, since: now };
  if (fails.count >= MAX_PAIR_FAILS) {
    const minutes = Math.ceil((fails.since + PAIR_LOCKOUT_MS - now) / 60000);
    return { ok: false, status: 429, error: `Too many wrong pairing codes. Pairing is locked for ${minutes} more minute${minutes === 1 ? "" : "s"}.` };
  }
  const code = (request.headers.get("x-pairing-code") || "").trim();
  if (!code || !timingSafeEqual(await sha256Hex(code), await sha256Hex(env.PAIRING_CODE))) {
    fails.count += 1;
    await env.DRIFT.put(PAIR_FAILS_KEY, JSON.stringify(fails));
    return { ok: false, error: "Wrong pairing code." };
  }
  if (fails.count) await env.DRIFT.delete(PAIR_FAILS_KEY);
  await env.DRIFT.put(OWNER_KEY, hash);
  return { ok: true };
}

function validateDelivery(d) {
  if (!d || typeof d !== "object") throw new Error("Missing delivery settings.");
  if (d.type === "ntfy") {
    const server = String(d.server || "https://ntfy.sh").replace(/\/+$/, "");
    const topic = String(d.topic || "");
    if (!/^[A-Za-z0-9_-]{12,64}$/.test(topic)) throw new Error("The ntfy topic must be 12–64 letters, digits, - or _.");
    if (!/^https:\/\//.test(server)) throw new Error("The ntfy server must use https.");
    return { type: "ntfy", server, topic };
  }
  if (d.type === "apns") {
    const token = String(d.token || "");
    if (!/^[0-9a-f]{64,200}$/i.test(token)) throw new Error("Invalid APNs device token.");
    return { type: "apns", token, environment: d.environment === "development" ? "development" : "production", topic: String(d.topic || "") };
  }
  throw new Error("Unknown delivery type.");
}

// ---------------------------------------------------------------------------
// Mail checking
// ---------------------------------------------------------------------------

async function loadConfig(env) {
  return env.DRIFT.get(CONFIG_KEY, "json");
}

async function checkAll(env, { baselineOnly = false, idleUntil = 0 } = {}) {
  const config = await loadConfig(env);
  if (!config || !config.accounts?.length) return {};
  const state = (await env.DRIFT.get(STATE_KEY, "json")) || {};
  const previousStatus = (await env.DRIFT.get(STATUS_KEY, "json")) || {};
  const errors = {};
  const persist = () => env.DRIFT.put(STATE_KEY, JSON.stringify(state));

  // Accounts run in parallel, each on its own connection.
  await Promise.all(
    config.accounts.map(async (account) => {
      try {
        await runAccount(env, config, account, state, { baselineOnly, idleUntil, persist });
      } catch (error) {
        errors[account.id] = String(error?.message || error).slice(0, 200);
      }
    })
  );

  // Drop state for removed accounts.
  let pruned = false;
  for (const id of Object.keys(state)) {
    if (!config.accounts.some((a) => a.id === id)) {
      delete state[id];
      pruned = true;
    }
  }
  if (pruned) await persist();

  // Write status only when errors change or every 30 minutes (keeps KV writes tiny).
  const now = Date.now();
  const lastRun = previousStatus.lastRun ? Date.parse(previousStatus.lastRun) : 0;
  const errorsChanged = JSON.stringify(errors) !== JSON.stringify(previousStatus.errors || {});
  if (errorsChanged || now - lastRun > 30 * 60 * 1000 || baselineOnly) {
    await env.DRIFT.put(STATUS_KEY, JSON.stringify({ lastRun: new Date(now).toISOString(), errors }));
  }
  return state;
}

/// Signs in, catches up on anything that arrived since the last run, then (when
/// `idleUntil` is set) waits in IMAP IDLE and notifies the moment mail arrives.
async function runAccount(env, config, account, state, { baselineOnly, idleUntil, persist }) {
  const password = await decrypt(env, account.password);
  const imap = new Imap(account.host, account.port);
  try {
    await imap.greeting();
    await imap.command(`LOGIN ${quote(account.username)} ${quote(password)}`);
    const capabilities = (await imap.command("CAPABILITY")).untagged.map((u) => u.text).join(" ");
    const examined = (await imap.command("EXAMINE INBOX")).untagged.map((u) => u.text).join("\n");
    const uidNext = Number((examined.match(/UIDNEXT (\d+)/i) || [])[1] || 0);
    const uidValidity = Number((examined.match(/UIDVALIDITY (\d+)/i) || [])[1] || 0);
    const previous = state[account.id];

    if (!previous || previous.uidValidity !== uidValidity || baselineOnly) {
      // First run (or the mailbox was rebuilt): remember where we are, notify nothing.
      if (!previous || previous.uidNext !== uidNext || previous.uidValidity !== uidValidity) {
        state[account.id] = { uidNext, uidValidity };
        await persist();
      }
      if (baselineOnly) return;
    } else if (uidNext > previous.uidNext) {
      await deliverNew(env, config, account, imap, state, persist);
    }

    if (!idleUntil || !/\bIDLE\b/i.test(capabilities)) return;
    // Live phase: the server pushes "* n EXISTS" the instant new mail lands.
    while (idleUntil - Date.now() > 3000) {
      const changed = await imap.idle(idleUntil - Date.now());
      if (!changed) break;
      await deliverNew(env, config, account, imap, state, persist);
    }
  } finally {
    imap.close();
  }
}

/// Private mode: with end-to-end encrypted native push the relay never downloads
/// sender or subject. It only learns that message #N arrived; the phone fetches
/// the details itself. The same applies whenever previews are turned off.
function relayReadsHeaders(config) {
  const zeroKnowledge = config.delivery?.type === "apns" && !!config.e2eKey;
  return !zeroKnowledge && config.showPreviews !== false;
}

/// Fetches messages from the remembered UID onward and notifies for unread ones.
async function deliverNew(env, config, account, imap, state, persist) {
  const from = state[account.id]?.uidNext || 1;
  const readHeaders = relayReadsHeaders(config);
  const items = readHeaders ? "(UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)])" : "(UID FLAGS)";
  const fetched = await imap.command(`UID FETCH ${from}:* ${items}`);
  const messages = [];
  let highest = 0;
  for (const u of fetched.untagged) {
    if (!/ FETCH /i.test(u.text)) continue;
    const uid = Number((u.text.match(/UID (\d+)/i) || [])[1] || 0);
    // "UID n:*" also returns the newest message when nothing is >= n; skip it.
    if (!uid || uid < from) continue;
    highest = Math.max(highest, uid);
    if (/\\Seen/i.test(u.text)) continue;
    if (!readHeaders) {
      messages.push({ uid, title: null, body: null });
      continue;
    }
    const headers = parseHeaders(u.literals.map((l) => decodeBytes(l)).join("\n"));
    messages.push({
      uid,
      title: displayName(decodeWords(headers.from || "")) || "New mail",
      body: decodeWords(headers.subject || "") || "(No subject)",
    });
  }
  if (!highest) return;
  // Save progress before sending so an overlapping run never notifies twice.
  state[account.id] = { ...state[account.id], uidNext: highest + 1 };
  await persist();
  messages.sort((a, b) => a.uid - b.uid);
  for (const message of messages.slice(-MAX_NOTIFICATIONS_PER_ACCOUNT)) {
    await deliver(env, config, { ...message, accountId: account.id, accountEmail: account.email });
  }
  const extra = messages.length - MAX_NOTIFICATIONS_PER_ACCOUNT;
  if (extra > 0) {
    await deliver(env, config, { title: account.email, body: `${extra} more new messages`, accountId: account.id, uid: null, more: extra });
  }
}

// ---------------------------------------------------------------------------
// Minimal IMAP over TLS (cloudflare:sockets)
// ---------------------------------------------------------------------------

const TIMED_OUT = Symbol("timeout");

class Imap {
  constructor(host, port) {
    this.socket = connect({ hostname: host, port }, { secureTransport: "on", allowHalfOpen: false });
    this.reader = this.socket.readable.getReader();
    this.writer = this.socket.writable.getWriter();
    this.buffer = new Uint8Array(0);
    this.pending = null;   // a read that outlived a timeout is reused, so no data is lost
    this.tag = 0;
    this.encoder = new TextEncoder();
  }

  close() {
    try { this.writer.write(this.encoder.encode("Z LOGOUT\r\n")).catch(() => {}); } catch {}
    try { this.socket.close(); } catch {}
  }

  /// Reads more bytes. Returns false on timeout when `soft`, otherwise throws.
  async fill(deadline, soft = false) {
    if (!this.pending) {
      this.pending = this.reader.read();
      this.pending.catch(() => {});
    }
    let timer;
    const timeout = new Promise((resolve) => { timer = setTimeout(() => resolve(TIMED_OUT), Math.max(0, deadline - Date.now())); });
    const result = await Promise.race([this.pending, timeout]);
    clearTimeout(timer);
    if (result === TIMED_OUT) {
      if (soft) return false;
      throw new Error("IMAP server timed out");
    }
    this.pending = null;
    const { value, done } = result;
    if (done) throw new Error("IMAP connection closed");
    const merged = new Uint8Array(this.buffer.length + value.length);
    merged.set(this.buffer);
    merged.set(value, this.buffer.length);
    this.buffer = merged;
    return true;
  }

  async readLine(deadline, soft = false) {
    while (true) {
      for (let i = 0; i + 1 < this.buffer.length; i++) {
        if (this.buffer[i] === 13 && this.buffer[i + 1] === 10) {
          const line = this.buffer.slice(0, i);
          this.buffer = this.buffer.slice(i + 2);
          return new TextDecoder("latin1").decode(line);
        }
      }
      if (!(await this.fill(deadline, soft))) return null;
    }
  }

  async readBytes(n) {
    while (this.buffer.length < n) await this.fill(Date.now() + 20000);
    const out = this.buffer.slice(0, n);
    this.buffer = this.buffer.slice(n);
    return out;
  }

  /// Reads one response; literals are collected separately. With `soft`, returns
  /// null if nothing arrives before the deadline.
  async readResponse(deadline = Date.now() + 20000, soft = false) {
    let text = "";
    const literals = [];
    let line = await this.readLine(deadline, soft);
    if (line === null) return null;
    while (true) {
      const m = line.match(/\{(\d+)\+?\}$/);
      text += line;
      if (!m) break;
      literals.push(await this.readBytes(Number(m[1])));
      text += " ";
      line = await this.readLine(Date.now() + 20000);
    }
    return { text, literals };
  }

  async greeting() {
    const r = await this.readResponse();
    if (!/^\* (OK|PREAUTH)/i.test(r.text)) throw new Error("Unexpected IMAP greeting");
  }

  async command(cmd) {
    const tag = `W${++this.tag}`;
    await this.writer.write(this.encoder.encode(`${tag} ${cmd}\r\n`));
    const untagged = [];
    while (true) {
      const r = await this.readResponse();
      if (r.text.startsWith(`${tag} `)) {
        const status = r.text.slice(tag.length + 1);
        if (!/^OK/i.test(status)) {
          const reason = status.replace(/^(NO|BAD)\s*/i, "");
          throw new Error(cmd.startsWith("LOGIN") ? `Sign-in failed: ${reason}` : reason);
        }
        return { untagged, status };
      }
      if (r.text.startsWith("*")) untagged.push(r);
    }
  }

  /// IMAP IDLE (RFC 2177). Resolves true as soon as new mail is announced,
  /// false when `ms` pass quietly.
  async idle(ms) {
    const tag = `W${++this.tag}`;
    await this.writer.write(this.encoder.encode(`${tag} IDLE\r\n`));
    while (true) {
      const r = await this.readResponse();
      if (r.text.startsWith("+")) break;
      if (r.text.startsWith(`${tag} `)) throw new Error(`IDLE refused: ${r.text}`);
    }
    const end = Date.now() + ms;
    let changed = false;
    while (!changed) {
      const r = await this.readResponse(end, true);
      if (r === null) break;
      if (/^\* \d+ EXISTS/i.test(r.text)) changed = true;
      else if (/^\* BYE/i.test(r.text)) throw new Error("The mail server ended the connection");
    }
    await this.writer.write(this.encoder.encode("DONE\r\n"));
    while (true) {
      const r = await this.readResponse();
      if (r.text.startsWith(`${tag} `)) break;
    }
    return changed;
  }
}

function quote(s) {
  return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}


// ---------------------------------------------------------------------------
// Header decoding
// ---------------------------------------------------------------------------

function decodeBytes(bytes) {
  try { return new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
  catch { return new TextDecoder("latin1").decode(bytes); }
}

function parseHeaders(text) {
  const out = {};
  const unfolded = text.replace(/\r?\n[ \t]+/g, " ");
  for (const line of unfolded.split(/\r?\n/)) {
    const i = line.indexOf(":");
    if (i > 0) out[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
  }
  return out;
}

function decodeWords(value) {
  return value
    .replace(/(=\?[^?]+\?[bBqQ]\?[^?]*\?=)\s+(?==\?)/g, "$1")
    .replace(/=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/g, (_, charset, mode, data) => {
      let bytes;
      if (mode.toUpperCase() === "B") {
        const bin = atob(data.replace(/[^A-Za-z0-9+/=]/g, ""));
        bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
      } else {
        const s = data.replace(/_/g, " ").replace(/=([0-9A-Fa-f]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));
        bytes = Uint8Array.from(s, (c) => c.charCodeAt(0));
      }
      try { return new TextDecoder(charset.toLowerCase().split("*")[0]).decode(bytes); }
      catch { return decodeBytes(bytes); }
    });
}

function displayName(from) {
  const m = from.match(/^\s*"?([^"<]*?)"?\s*<([^>]+)>/);
  if (m) return m[1].trim() || m[2].trim();
  return from.trim();
}

// ---------------------------------------------------------------------------
// Delivery
// ---------------------------------------------------------------------------

async function deliver(env, config, message) {
  const preview = config.showPreviews !== false && message.title != null;
  const title = preview ? message.title : "New mail";
  const body = preview ? message.body : (message.accountEmail ? `in ${message.accountEmail}` : "Open DriftMail to read it.");
  const params = new URLSearchParams();
  if (message.accountId) params.set("account", message.accountId);
  if (message.uid) params.set("uid", String(message.uid));
  params.set("mailbox", "INBOX");
  const click = `driftmail://message?${params.toString()}`;

  const d = config.delivery;
  if (d.type === "ntfy") {
    const response = await fetch(`${d.server}/`, {
      method: "POST",
      headers: { "content-type": "application/json", ...(env.NTFY_TOKEN ? { authorization: `Bearer ${env.NTFY_TOKEN}` } : {}) },
      body: JSON.stringify({ topic: d.topic, title, message: body, click, tags: ["envelope"], priority: 4 }),
    });
    if (!response.ok) throw new Error(`ntfy answered ${response.status}`);
    return;
  }

  if (d.type === "apns") {
    const jwt = await apnsJWT(env);
    const reference = { account: message.accountId, uid: message.uid, mailbox: "INBOX" };
    let payload;
    if (config.e2eKey) {
      // End-to-end encrypted: Apple only sees a placeholder and ciphertext.
      // DriftMail's notification extension decrypts it on the phone.
      // Only a reference to the message: the phone fetches sender and subject itself.
      const secret = { ...reference };
      if (message.more) secret.more = message.more;
      if (message.test) Object.assign(secret, { title: message.title, body: message.body });
      const sealed = await sealForPhone(env, config.e2eKey, secret);
      payload = {
        aps: { alert: { title: "DriftMail", body: "New mail" }, sound: "default", "mutable-content": 1, "thread-id": "driftmail", category: "NEW_MAIL" },
        enc: sealed,
      };
    } else {
      payload = {
        aps: { alert: { title, body }, sound: "default", "thread-id": message.accountId || "driftmail", category: "NEW_MAIL" },
        ...reference,
      };
    }
    const send = (environment) => fetch(`https://${environment === "development" ? "api.sandbox.push.apple.com" : "api.push.apple.com"}/3/device/${d.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": env.APNS_BUNDLE_ID || d.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    let response = await send(d.environment);
    if (response.status === 400) {
      const text = await response.text();
      if (!/BadDeviceToken/.test(text)) throw new Error(`APNs answered 400: ${text}`);
      // The phone may not know which push environment it was signed for (re-signed
      // builds often lack embedded.mobileprovision, so it guesses "production"
      // even with a development certificate). Try the other environment and
      // remember whichever one Apple accepts.
      const other = d.environment === "development" ? "production" : "development";
      response = await send(other);
      if (response.ok) {
        d.environment = other;
        d.learnedEnvironment = other;
        await env.DRIFT.put(CONFIG_KEY, JSON.stringify(config));
        return;
      }
      throw new Error(`APNs rejected the device token in both environments (${response.status}: ${await response.text()}). Check that the Apple Push key and the signing profile belong to the same team.`);
    }
    if (!response.ok) throw new Error(`APNs answered ${response.status}: ${await response.text()}`);
  }
}

/// AES-256-GCM with the phone's key. Output: base64(nonce | ciphertext | tag),
/// which is exactly CryptoKit's AES.GCM.SealedBox "combined" format.
async function sealForPhone(env, storedKey, object) {
  const raw = fromB64(await decrypt(env, storedKey));
  const key = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const data = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(JSON.stringify(object))));
  const combined = new Uint8Array(iv.length + data.length);
  combined.set(iv);
  combined.set(data, iv.length);
  let bin = "";
  for (const b of combined) bin += String.fromCharCode(b);
  return btoa(bin);
}

/// Apple wants a provider token refreshed at most every 20 minutes; cache it for 45.
async function apnsJWT(env) {
  if (!env.APNS_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) {
    throw new Error("Native push needs the APNS_KEY, APNS_KEY_ID and APNS_TEAM_ID secrets.");
  }
  const cached = await env.DRIFT.get(APNS_JWT_KEY, "json");
  const now = Math.floor(Date.now() / 1000);
  if (cached && now - cached.iat < 45 * 60) return cached.token;

  const pem = env.APNS_KEY.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = b64url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const claims = b64url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }));
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`));
  const token = `${header}.${claims}.${b64url(new Uint8Array(signature))}`;
  await env.DRIFT.put(APNS_JWT_KEY, JSON.stringify({ token, iat: now }));
  return token;
}

// ---------------------------------------------------------------------------
// Crypto helpers
// ---------------------------------------------------------------------------

async function encryptionKey(env) {
  let secret = env.ENC_KEY;
  if (!secret) {
    // No secret configured: generate one and keep it in KV (still encrypted at rest by Cloudflare).
    secret = await env.DRIFT.get("enc-key");
    if (!secret) {
      secret = b64url(crypto.getRandomValues(new Uint8Array(32)));
      await env.DRIFT.put("enc-key", secret);
    }
  }
  const raw = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret));
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}

async function encrypt(env, text) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await encryptionKey(env);
  const data = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(text));
  return `${b64url(iv)}.${b64url(new Uint8Array(data))}`;
}

async function decrypt(env, value) {
  const [ivPart, dataPart] = value.split(".");
  const key = await encryptionKey(env);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromB64url(ivPart) }, key, fromB64url(dataPart));
  return new TextDecoder().decode(plain);
}

function b64url(input) {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromB64(s) {
  try { return Uint8Array.from(atob(s), (c) => c.charCodeAt(0)); } catch { return new Uint8Array(0); }
}

function fromB64url(s) {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}
