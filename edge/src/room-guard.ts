// What a room keeps is read by other people: the members' agents, anyone
// granted access later (they page back through history), and the console
// transcript. The agents writing into it run on people's own machines, with
// their files and environment in reach, and some of what they read comes from
// strangers. An agent that answers "paste your env so I can debug this" is the
// failure this guards against, so every post is checked before it is stored
// or wakes anyone:
//
//   - Credentials are refused (422 secret_detected). The error names the kind
//     and the line, never the value, and the agent rewrites and posts again.
//     Refusing beats redacting: a pattern that catches part of a multi-line key
//     would publish the rest.
//   - Personal details are rewritten in place: a home directory loses the
//     account name, email addresses, IPv4 addresses and machine names become
//     placeholders. The result says what was rewritten.
//   - Invisible text is removed: Unicode tag characters and variation
//     selectors used to hide instructions from the people reading a room,
//     bidi overrides that make a transcript read differently from what the
//     agents were sent, and zero-width characters wedged between ASCII
//     characters to split a key or an address (emoji joiners and the
//     non-joiners some scripts need are left alone).
//
// The check runs on every post, not only in rooms shared with someone else: a
// later invite reads the history. Keys are also looked for after undoing JSON
// escapes, percent-encoding and one layer of base64, and fullwidth letters are
// folded to ASCII first. Every pattern is linear (bounded or non-overlapping
// repetition) because this runs inside the room's serial queue.

export type SecretKind =
  | "private key"
  | "access token"
  | "API key"
  | "cloud credential"
  | "webhook URL"
  | "bot token"
  | "JSON web token"
  | "authorization header"
  | "cookie"
  | "password in a URL"
  | "signed URL"
  | "secret assignment"
  | "wallet key";

export type PersonalKind = "home_path" | "email" | "ip" | "device_name";

export interface Finding {
  kind: SecretKind;
  line: number;
  /** Where it was found: the text itself, or text decoded from it. */
  via: "text" | "json escapes" | "percent-encoding" | "base64";
}

export interface Guarded {
  text: string;
  redacted: Partial<Record<PersonalKind, number>>;
  /** Invisible characters removed. */
  stripped: number;
}

// --- Invisible text ---------------------------------------------------------

/** Tag characters (U+E0000-E007F) and variation selectors 17-256 carry text
 * no reader sees; bidi embeddings, overrides and isolates reorder what they do. */
const HIDDEN_ALWAYS = /[\u{E0000}-\u{E007F}\u{E0100}-\u{E01EF}‪-‮⁦-⁩]/gu;
/** Zero-width and soft-hyphen characters between two visible ASCII characters
 * only: that is where they split a key or an address. Elsewhere they join
 * emoji and shape scripts. */
const HIDDEN_BETWEEN_ASCII = /(?<=[\x21-\x7E])[​-‍⁠-⁤﻿­]+(?=[\x21-\x7E])/g;
/** Fullwidth digits, letters and the characters keys and addresses use. */
const FULLWIDTH = /[０-９Ａ-Ｚａ-ｚ＠＿．－／：]/g;

export function stripHidden(text: string): { text: string; stripped: number } {
  let stripped = 0;
  const count = (m: string) => {
    stripped += [...m].length;
    return "";
  };
  const out = text
    .replace(HIDDEN_ALWAYS, count)
    .replace(HIDDEN_BETWEEN_ASCII, count)
    .replace(FULLWIDTH, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0));
  return { text: out, stripped };
}

// --- Credentials -----------------------------------------------------------

interface Pattern {
  kind: SecretKind;
  re: RegExp;
  /** When set, capture group 1 must also pass this check. */
  value?: (v: string) => boolean;
}

// Prefixed formats. The prefixes are what the issuers publish so that
// scanners like this one can find them.
const PATTERNS: Pattern[] = [
  // The header and the start of a body: the header alone is someone talking
  // about keys. PGP armor may put a few `Name: value` lines in between.
  {
    kind: "private key",
    re: /-----BEGIN (?:[A-Z0-9]+ ){0,4}PRIVATE KEY(?: BLOCK)?-----[ \t]*(?:\\r|\\n|\r|\n)+(?:[A-Za-z-]{1,32}: [^\r\n]{0,80}(?:\\r|\\n|\r|\n)+){0,4}[A-Za-z0-9+/]{40}/g
  },
  { kind: "private key", re: /PuTTY-User-Key-File-\d+:/g },
  { kind: "private key", re: /\bAGE-SECRET-KEY-1[0-9A-Z]{50,}/g },
  { kind: "access token", re: /\b(?:cg_(?:sk|lt|rt)_|harness_rt_)[A-Za-z0-9._-]{16,}/g },
  { kind: "access token", re: /\bgh[pousr]_[A-Za-z0-9]{36,}/g },
  { kind: "access token", re: /\bgithub_pat_[A-Za-z0-9_]{50,}/g },
  { kind: "access token", re: /\bglpat-[A-Za-z0-9_-]{20,}/g },
  { kind: "access token", re: /\bxox[abposr]-[A-Za-z0-9-]{10,}/g },
  { kind: "access token", re: /\bnpm_[A-Za-z0-9]{36,}/g },
  { kind: "access token", re: /\bpypi-[A-Za-z0-9_-]{50,}/g },
  { kind: "access token", re: /\bdckr_pat_[A-Za-z0-9_-]{20,}/g },
  { kind: "access token", re: /\bhf_[A-Za-z0-9]{30,}/g },
  { kind: "access token", re: /\b(?:dop|doo|dor)_v1_[a-f0-9]{64}/g },
  { kind: "access token", re: /\bshp(?:at|ca|pa|ss)_[a-fA-F0-9]{32}/g },
  { kind: "access token", re: /\blin_api_[A-Za-z0-9]{40}/g },
  { kind: "API key", re: /\bsk-(?:[a-z]{2,8}-){0,2}[A-Za-z0-9_-]{32,}/g },
  { kind: "API key", re: /\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}/g },
  { kind: "API key", re: /\bwhsec_[A-Za-z0-9+/]{24,}/g },
  { kind: "API key", re: /\bSG\.[A-Za-z0-9_-]{16,32}\.[A-Za-z0-9_-]{32,64}/g },
  { kind: "API key", re: /\bSK[0-9a-f]{32}\b/g },
  { kind: "API key", re: /\bAIza[A-Za-z0-9_-]{35}/g },
  { kind: "cloud credential", re: /\b(?:AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}\b/g },
  { kind: "cloud credential", re: /"type"\s*:\s*"service_account"/g },
  { kind: "webhook URL", re: /hooks\.slack\.com\/(?:services|workflows|triggers)\/[A-Za-z0-9]+\/[A-Za-z0-9]+\/[A-Za-z0-9]{16,}/g },
  { kind: "webhook URL", re: /discord(?:app)?\.com\/api\/webhooks\/\d{5,}\/[A-Za-z0-9_-]{40,}/g },
  { kind: "webhook URL", re: /[a-z0-9-]+\.webhook\.office\.com\/webhookb2\/[A-Za-z0-9@-]{20,}\/[A-Za-z0-9\/@-]{20,}/gi },
  { kind: "bot token", re: /\b\d{8,10}:AA[A-Za-z0-9_-]{33}\b/g },
  { kind: "bot token", re: /\b[MNO][A-Za-z0-9_-]{23,25}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,38}\b/g },
  // Three segments (JWS) or five with an empty key segment (JWE dir).
  { kind: "JSON web token", re: /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]{10,}/g },
  {
    kind: "authorization header",
    re: /\b(?:proxy-)?authorization\s*[:=]\s*["']?(?:bearer|basic|token|digest)\s+([A-Za-z0-9._~+/=-]{12,})/gi,
    value: (v) => plausibleToken(v)
  },
  // Solana-style keypair file: a JSON array of 64 bytes.
  { kind: "wallet key", re: /\[\s*(?:\d{1,3}\s*,\s*){63}\d{1,3}\s*\]/g }
];

/** Lowercase words joined by `-`, `_` or `.` (`still-valid`, `token-alice`,
 * `key_abc123`): what people type into fixtures, not what issuers mint. */
const HUMAN_WORDS = /^[a-z]+(?:[-_.][a-z0-9]{1,12}){0,12}$/;

/** A value that could have been minted rather than written by hand or
 * filled in by a template. */
function plausibleToken(v: string): boolean {
  if (PLACEHOLDER_VALUE.test(v) || placeholder(v) || HUMAN_WORDS.test(v)) return false;
  return !/[${}@]/.test(v);
}

/** A documented example or a run of one character, not a credential. */
function placeholder(match: string): boolean {
  // `cg_sk_...` in docs: a truncated example is never the real thing.
  if (/EXAMPLE|example|x{8,}|X{8,}|\*{4,}|0{12,}|1234567890|\.\.\.|\u2026/.test(match)) return true;
  const runs = match.match(/[A-Za-z0-9]{8,}/g);
  if (!runs) return false;
  const longest = runs.reduce((a, b) => (b.length > a.length ? b : a));
  return new Set(longest).size < 5;
}

// Whole-value placeholders, and values that announce themselves as one
// (`your-api-key-here`, `example_token`). Not `secret_…` or `test_…`: real
// keys start that way.
const PLACEHOLDER_VALUE =
  /^(?:x+|\*+|\.+|-+|_+|#+|<[^>]*>|\{\{.*\}\}|\$\{.*\}|\$\(.*\)|\$[A-Za-z_]\w*|%[A-Za-z_]\w*%|(?:your|example|sample|dummy|fake|placeholder|changeme|change-me|redacted|xxx|todo|tbd)(?:[\W_].*)?|(?:secret|password|pass|test|none|null|nil|undefined|true|false|string|required|optional)s?)$/i;

/** Key names that hold a credential, by segment: `db_password`, `apiKey`,
 * `CLIENT_SECRET`, `x-auth-token`, but not `max_tokens`, `tokenizer` or
 * `token_path`. */
function secretKey(name: string): boolean {
  const parts = name
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .toLowerCase()
    .split(/[_.\-]+/)
    .filter(Boolean);
  const single = new Set(["secret", "secrets", "password", "passwd", "pwd", "passphrase", "token", "credential", "credentials", "mnemonic", "apikey", "accesskey", "privatekey", "secretkey", "authkey", "pat"]);
  const keyed = new Set(["api", "access", "private", "secret", "signing", "auth", "client", "master", "encryption", "session", "account"]);
  // The credential word ends the name: `api_token` holds one, `token_path`,
  // `TokenError` and `tokenColors` hold something about one.
  const last = parts.length - 1;
  if (last < 0) return false;
  if (single.has(parts[last])) return true;
  return (parts[last] === "key" || parts[last] === "keys") && last > 0 && keyed.has(parts[last - 1]);
}

/** A value that could be a credential rather than code, a count or a type. */
function credentialValue(key: string, raw: string): boolean {
  const v = raw.replace(/^["'`]|["'`]$/g, "").replace(/[!?]+$/, ""); // `process.env.X!`
  const short = /(?:^|[_.\-])(?:password|passwd|pwd|passphrase)$/i.test(key) || /pass(?:word|wd|phrase)$/i.test(key);
  if (v.length < (short ? 6 : 8)) return false;
  if (PLACEHOLDER_VALUE.test(v)) return false;
  if (/^[\d.,_]+$/.test(v)) return false; // counts and versions
  if (/[()[\]{}<>$@]/.test(v)) return false; // calls, generics, templates, dev logins
  if (v.includes("::") || /^[&*!:=]/.test(v)) return false; // paths, borrows, `=>`, `::`
  if (!short && HUMAN_WORDS.test(v)) return false;
  if (/^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+$/.test(v)) return false; // process.env.X
  if (/^[A-Za-z_]+$/.test(v) && v.length < 32) return false; // identifiers
  if (/^(?:https?|file):\/\//.test(v)) return false; // URLs are checked on their own
  if (placeholder(v)) return false;
  const classes = [/[a-z]/, /[A-Z]/, /\d/, /[^A-Za-z0-9]/].filter((c) => c.test(v)).length;
  return classes >= 2 || v.length >= 32;
}

// `KEY = value`, `KEY: value`, `"key": "value"`, `export KEY=value`.
const ASSIGNMENT = /(?<![A-Za-z0-9_.-])([A-Za-z_][A-Za-z0-9_.-]{0,63})["']?[ \t]{0,3}[:=][ \t]{0,3}(["'`]?[^\s"'`,;&]{6,256}["'`]?)/g;
// scheme://user:password@host
const URL_CREDENTIALS = /\b[a-z][a-z0-9+.-]{1,20}:\/\/([^\s:@/"'`,;<>]{0,64}):([^\s@/"'`,;<>]{1,128})@([^\s/:?#"'`,;<>)\]}]{1,255})/gi;
// ?token=…, &X-Amz-Signature=…
const QUERY_SECRET = /[?&]((?:access_|refresh_|id_|auth_|api_?)?token|api_?key|apikey|key|secret|client_secret|password|sig|signature|x-amz-signature|x-amz-credential|x-goog-signature|sv|se)=([^&\s#"'<>]{12,})/gi;
const COOKIE_LINE = /\b(?:set-)?cookie\s*:[^\n]{0,4096}/gi;

const LOCAL_HOST = /^(?:localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[?::1\]?|[^.]+\.(?:test|example|invalid|localhost)|example\.(?:com|org|net))$/i;

function lineOf(text: string, index: number): number {
  let line = 1;
  for (let i = 0; i < index && i < text.length; i++) if (text.charCodeAt(i) === 10) line++;
  return line;
}

function scanPlain(text: string, via: Finding["via"], lineBase?: number): Finding | null {
  const at = (index: number) => lineBase ?? lineOf(text, index);
  for (const { kind, re, value } of PATTERNS) {
    re.lastIndex = 0;
    for (let m = re.exec(text); m; m = re.exec(text)) {
      if (placeholder(m[0])) continue;
      if (value && !value(m[1] ?? "")) continue;
      return { kind, line: at(m.index), via };
    }
  }
  URL_CREDENTIALS.lastIndex = 0;
  for (let m = URL_CREDENTIALS.exec(text); m; m = URL_CREDENTIALS.exec(text)) {
    const [, , password, host] = m;
    if (LOCAL_HOST.test(host) || !plausibleToken(password)) continue;
    return { kind: "password in a URL", line: at(m.index), via };
  }
  QUERY_SECRET.lastIndex = 0;
  for (let m = QUERY_SECRET.exec(text); m; m = QUERY_SECRET.exec(text)) {
    const name = m[1].toLowerCase();
    const value = decodeURIComponentSafe(m[2]);
    if (!plausibleToken(value)) continue;
    if (name === "key" || name === "sv" || name === "se") {
      // Too common as plain parameters; only a credential-shaped value counts.
      if (!credentialValue("secret", value) || value.length < 20) continue;
    }
    const signed = /signature|credential|^sig$/.test(name);
    return { kind: signed ? "signed URL" : "secret assignment", line: at(m.index), via };
  }
  COOKIE_LINE.lastIndex = 0;
  for (let m = COOKIE_LINE.exec(text); m; m = COOKIE_LINE.exec(text)) {
    const pairs = m[0].slice(m[0].indexOf(":") + 1).split(";");
    for (const pair of pairs) {
      const eq = pair.indexOf("=");
      if (eq < 0) continue;
      const name = pair.slice(0, eq).trim().toLowerCase();
      const value = pair.slice(eq + 1).trim();
      if (["path", "domain", "expires", "max-age", "samesite"].includes(name)) continue;
      // Cookie values never hold spaces; a sentence after "cookie:" is prose.
      if (value.length >= 16 && !/\s/.test(value) && plausibleToken(value)) {
        return { kind: "cookie", line: at(m.index), via };
      }
    }
  }
  ASSIGNMENT.lastIndex = 0;
  for (let m = ASSIGNMENT.exec(text); m; m = ASSIGNMENT.exec(text)) {
    const [, key, value] = m;
    if (secretKey(key) && credentialValue(key, value)) return { kind: "secret assignment", line: at(m.index), via };
  }
  return null;
}

function decodeURIComponentSafe(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}

function unescapeJson(text: string): string {
  return text.replace(/\\(?:u([0-9a-fA-F]{4})|([nrt"\\/]))/g, (_, hex: string | undefined, c: string | undefined) => {
    if (hex) return String.fromCharCode(parseInt(hex, 16));
    return c === "n" ? "\n" : c === "r" ? "\r" : c === "t" ? "\t" : (c as string);
  });
}

const BASE64_RUN = /[A-Za-z0-9+/_-]{32,}={0,2}/g;

function decodeBase64(run: string): string | null {
  const std = run.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  if (std.length % 4 === 1) return null;
  let bytes: string;
  try {
    bytes = atob(std + "=".repeat((4 - (std.length % 4)) % 4));
  } catch {
    return null;
  }
  let printable = 0;
  for (let i = 0; i < bytes.length; i++) {
    const c = bytes.charCodeAt(i);
    if ((c >= 0x20 && c < 0x7f) || c === 9 || c === 10 || c === 13) printable++;
  }
  return bytes.length > 0 && printable / bytes.length > 0.9 ? bytes : null;
}

/** The first credential in `text`, or null. Also looks through JSON escapes,
 * percent-encoding and one layer of base64. */
export function findSecret(text: string): Finding | null {
  const direct = scanPlain(text, "text");
  if (direct) return direct;
  if (/\\[nu"\\/]/.test(text)) {
    const json = unescapeJson(text);
    if (json !== text) {
      const f = scanPlain(json, "json escapes");
      if (f) return f;
    }
  }
  if (/%[0-9A-Fa-f]{2}/.test(text)) {
    const decoded = text.replace(/(?:%[0-9A-Fa-f]{2})+/g, (run) => decodeURIComponentSafe(run));
    if (decoded !== text) {
      const f = scanPlain(decoded, "percent-encoding");
      if (f) return f;
    }
  }
  BASE64_RUN.lastIndex = 0;
  for (let m = BASE64_RUN.exec(text); m; m = BASE64_RUN.exec(text)) {
    const decoded = decodeBase64(m[0]);
    if (decoded === null) continue;
    const f = scanPlain(decoded, "base64", lineOf(text, m.index));
    if (f) return f;
  }
  return null;
}

// --- Personal details --------------------------------------------------------

const HOME_POSIX = /(?<![A-Za-z0-9_])\/(?:Users|home)\/(?!Shared\b)([^/\s"'`:;,)\]}]{1,64})/g;
// Windows account names may hold spaces; a spaced one counts only when a
// path separator follows it, so prose after a bare `C:\Users\bob` survives.
const HOME_WINDOWS =
  /\b[A-Za-z]:(?:\\{1,2}|\/)Users(?:\\{1,2}|\/)(?!Public\b|Default\b)(?:[^\\/\s"'`:;,)\]}]{1,64}(?: [^\\/\s"'`:;,)\]}]{1,64}){1,3}(?=\\|\/)|[^\\/\s"'`:;,)\]}]{1,64})/gi;
const EMAIL = /(?<![A-Za-z0-9._%+-])([A-Za-z0-9._%+-]{1,64})@([A-Za-z0-9-]{1,63}(?:\.[A-Za-z0-9-]{1,63}){0,8}\.[A-Za-z]{2,24})\b/g;
const OCTET = "(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)";
const IPV4 = new RegExp(`(?<![\\w.])${OCTET}(?:\\.${OCTET}){3}(?![\\w]|\\.\\d)`, "g");
// `alices-macbook-pro.local`, not `self.local.open`, `.env.local` or `mesh.local`.
const MDNS = /(?<![\w.-])[A-Za-z0-9]{1,40}(?:-[A-Za-z0-9]{1,40}){1,5}\.local(?![\w.-])/g;
const DEVICES = "(?:MacBook(?:[- ](?:Pro|Air))?|iMac(?:[- ]Pro)?|Mac[- ](?:mini|Studio|Pro)|iPhone|iPad(?:[- ](?:Pro|Air|mini))?)";
const DEVICE_NAME_HOST = new RegExp(`\\b[A-Za-z0-9]{2,32}s?-${DEVICES}(?:-[A-Za-z0-9]{1,8}){0,2}\\b`, "g");
const DEVICE_NAME_TEXT = new RegExp(`(?<![\\p{L}\\p{N}])\\p{Lu}[\\p{L}]{1,31}['’]s ${DEVICES}\\b`, "gu");

const KEEP_EMAIL_DOMAIN = /(?:^|\.)(?:example\.(?:com|org|net)|[^.]+\.(?:example|test|invalid|localhost)|users\.noreply\.github\.com|noreply\.github\.com)$/i;
const KEEP_EMAIL_USER = /^(?:git|noreply|no-reply)$/i;
/** `logo@2x.png`, `prefix@README.md`: file names, not addresses. */
const FILE_TLD = /\.(?:mdx?|tsx?|jsx?|mjs|cjs|rs|py|png|jpe?g|gif|svg|webp|ico|json|ya?ml|toml|txt|lock|html?|css|scss|swift|go|zig|rb|java|kt|cpp|hpp|sql|log|zip|gz|tar|wasm|pdf)$/i;

function keepIp(ip: string): boolean {
  const [a, b, c] = ip.split(".").map(Number);
  if (a === 0 || a === 127 || a === 255) return true; // this-network, loopback, masks
  if (ip.split(".").every((o) => o.length === 1)) return true; // 2.6.1.3: a section or version
  // Documentation ranges (RFC 5737).
  if ((a === 192 && b === 0 && c === 2) || (a === 198 && b === 51 && c === 100) || (a === 203 && b === 0 && c === 113)) return true;
  return ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9"].includes(ip); // public resolvers
}

export function redactPersonal(text: string): { text: string; redacted: Partial<Record<PersonalKind, number>> } {
  const redacted: Partial<Record<PersonalKind, number>> = {};
  const bump = (k: PersonalKind) => (redacted[k] = (redacted[k] ?? 0) + 1);
  const out = text
    .replace(HOME_POSIX, () => (bump("home_path"), "~"))
    .replace(HOME_WINDOWS, () => (bump("home_path"), "~"))
    .replace(EMAIL, (whole, user: string, domain: string) => {
      if (KEEP_EMAIL_DOMAIN.test(domain) || KEEP_EMAIL_USER.test(user) || FILE_TLD.test(domain)) return whole;
      bump("email");
      return "[email]";
    })
    .replace(IPV4, (ip) => (keepIp(ip) ? ip : (bump("ip"), "[ip]")))
    .replace(MDNS, () => (bump("device_name"), "[device].local"))
    .replace(DEVICE_NAME_HOST, () => (bump("device_name"), "[device]"))
    .replace(DEVICE_NAME_TEXT, () => (bump("device_name"), "[device]"));
  return { text: out, redacted };
}

// --- Entry points --------------------------------------------------------------

export class GuardRefusal extends Error {
  constructor(
    readonly field: string,
    readonly finding: Finding
  ) {
    const where = finding.via === "text" ? `line ${finding.line}` : `line ${finding.line}, after undoing ${finding.via}`;
    const article = /^[aeiou]/i.test(finding.kind) ? "an" : "a";
    super(
      `${field}: looks like ${article} ${finding.kind} (${where}). Rooms are read by other people and their agents; ` +
        "remove it and post again. Refer to credentials by name, never by value."
    );
  }
}

/** Free text other people will read: strips hidden characters, refuses
 * credentials, rewrites personal details. */
export function guardText(field: string, text: string): Guarded {
  const hidden = stripHidden(text);
  const secret = findSecret(hidden.text);
  if (secret) throw new GuardRefusal(field, secret);
  const personal = redactPersonal(hidden.text);
  return { text: personal.text, redacted: personal.redacted, stripped: hidden.stripped };
}

/** Identifiers that are stored and shown as-is (claim keys, client ids,
 * member names): refused rather than rewritten, since rewriting one would
 * change what it refers to. */
export function guardIdentifier(field: string, value: string): void {
  if (stripHidden(value).text !== value) throw new IdentifierRefusal(field, "invisible or fullwidth characters");
  const secret = findSecret(value);
  if (secret) throw new GuardRefusal(field, secret);
  const personal = redactPersonal(value);
  if (personal.text !== value) {
    throw new IdentifierRefusal(field, `a personal detail (${Object.keys(personal.redacted).join(", ").replace(/_/g, " ")})`);
  }
}

export class IdentifierRefusal extends Error {
  constructor(
    readonly field: string,
    what: string
  ) {
    super(`${field}: contains ${what}; pick a name that doesn't`);
  }
}
