/**
 * Crash and hang reports from Harness on iOS: the MetricKit diagnostic
 * payloads CrashReports.swift saves, uploaded once each to
 * `POST /diagnostics/crash-reports` as a JSON array. They are stored in
 * PostgreSQL (`app.harness_crash_reports`), where codegraff.com's
 * /admin/crashes reads them; the account purge deletes a person's rows.
 *
 * A report holds code addresses, the build, the device model and the iOS
 * version, never chat content. The edge keeps the payload as sent and pulls
 * out what the admin list needs, so nothing on the phone has to agree with it.
 */
import { withPg, type PgEnv } from "./pg";

/** One upload: the phone sends what it has in batches no larger than this. */
export const MAX_CRASH_UPLOAD_BYTES = 1024 * 1024;
export const MAX_CRASH_REPORTS_PER_UPLOAD = 10;

export type CrashKind = "crash" | "hang" | "cpu" | "disk" | "launch" | "other";

export interface CrashRow {
  digest: string;
  kind: CrashKind;
  headline: string;
  signature: string | null;
  appVersion: string | null;
  appBuild: string | null;
  osVersion: string | null;
  deviceType: string | null;
  crashCount: number;
  hangCount: number;
  payload: string;
}

type Json = Record<string, unknown>;

const KINDS: [string, CrashKind][] = [
  ["crashDiagnostics", "crash"],
  ["hangDiagnostics", "hang"],
  ["cpuExceptionDiagnostics", "cpu"],
  ["diskWriteExceptionDiagnostics", "disk"],
  ["appLaunchDiagnostics", "launch"]
];

/** Frames that make up a crash's signature, from the top of the crashed thread. */
const SIGNATURE_FRAMES = 6;

const SIGNALS: Record<number, string> = { 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV" };
const EXCEPTIONS: Record<number, string> = {
  1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 6: "EXC_BREAKPOINT",
  10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD"
};

const list = (root: Json, key: string): Json[] =>
  Array.isArray(root[key]) ? (root[key] as unknown[]).filter((x): x is Json => !!x && typeof x === "object") : [];
const meta = (item: Json | undefined): Json =>
  item && typeof item.diagnosticMetaData === "object" && item.diagnosticMetaData ? (item.diagnosticMetaData as Json) : {};
const text = (value: unknown, max: number): string | null =>
  typeof value === "string" && value.trim() ? value.trim().slice(0, max) : null;

const hex = async (data: string): Promise<string> => {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(data));
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0")).join("");
};

/** Same wording as the phone's list (CrashReports.crashHeadline). */
export const crashHeadline = (m: Json): string => {
  const reason = typeof m.terminationReason === "string" ? m.terminationReason.split(/\r?\n/)[0].trim() : "";
  if (reason) return "Crash: " + (reason.length > 90 ? reason.slice(0, 89) + "…" : reason);
  const exception = typeof m.exceptionType === "number" ? (EXCEPTIONS[m.exceptionType] ?? `exception ${m.exceptionType}`) : null;
  const signal = typeof m.signal === "number" ? (SIGNALS[m.signal] ?? `signal ${m.signal}`) : null;
  const parts = [exception, signal].filter(Boolean);
  return parts.length ? "Crash: " + parts.join(" · ") : "Crash";
};

/** The top frames of the thread the diagnostic blames (or its first), as `binary+offset`. */
export const topFrames = (diagnostic: Json | undefined, count = SIGNATURE_FRAMES): string[] => {
  const tree = diagnostic?.callStackTree as Json | undefined;
  const stacks = tree ? list(tree, "callStacks") : [];
  const stack = stacks.find((s) => s.threadAttributed === true) ?? stacks[0];
  const out: string[] = [];
  let frame = stack ? list(stack, "callStackRootFrames")[0] : undefined;
  while (frame && out.length < count) {
    out.push(`${String(frame.binaryName ?? "?")}+${String(frame.offsetIntoBinaryImage ?? "?")}`);
    frame = list(frame, "subFrames")[0];
  }
  return out;
};

/** What the admin list needs from one MetricKit payload. */
export const summarize = async (report: Json): Promise<CrashRow> => {
  const payload = JSON.stringify(report);
  let kind: CrashKind = "other";
  let first: Json | undefined;
  for (const [key, k] of KINDS) {
    const items = list(report, key);
    if (items.length) {
      kind = k;
      first = items[0];
      break;
    }
  }
  const m = meta(first);
  let headline = "Diagnostics";
  if (kind === "crash") headline = crashHeadline(m);
  else if (kind === "hang") headline = text(m.hangDuration, 40) ? `Hang (${text(m.hangDuration, 40)})` : "Hang";
  else if (kind === "cpu") headline = "Too much CPU in the background";
  else if (kind === "disk") headline = "Heavy disk writes";
  else if (kind === "launch") headline = text(m.launchDuration, 40) ? `Slow launch (${text(m.launchDuration, 40)})` : "Slow launch";
  const frames = kind === "crash" || kind === "hang" ? topFrames(first) : [];
  const exception = `${String(m.exceptionType ?? "")}/${String(m.signal ?? "")}`;
  return {
    digest: await hex(payload),
    kind,
    headline,
    signature: frames.length ? (await hex([kind, exception, ...frames].join("\n"))).slice(0, 16) : null,
    appVersion: text(m.appVersion, 40),
    appBuild: text(m.appBuildVersion, 40),
    osVersion: text(m.osVersion, 80),
    deviceType: text(m.deviceType, 40),
    crashCount: list(report, "crashDiagnostics").length,
    hangCount: list(report, "hangDiagnostics").length,
    payload
  };
};

/** Parse an upload body: a JSON array of payload objects, within the limits. */
export const parseUpload = (body: string): Json[] | { error: string; status: number } => {
  if (body.length > MAX_CRASH_UPLOAD_BYTES) return { error: "too_large", status: 413 };
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return { error: "bad_json", status: 400 };
  }
  if (!Array.isArray(parsed) || parsed.length === 0) return { error: "expected a non-empty array", status: 400 };
  if (parsed.length > MAX_CRASH_REPORTS_PER_UPLOAD) return { error: "too_many", status: 413 };
  if (!parsed.every((r) => r && typeof r === "object" && !Array.isArray(r))) {
    return { error: "expected report objects", status: 400 };
  }
  return parsed as Json[];
};

/** Store a batch; a report already stored for this person is skipped. Returns how many were new. */
export const storeCrashReports = (env: PgEnv, userId: string, rows: CrashRow[]): Promise<number> =>
  withPg(env, async (pg) => {
    let stored = 0;
    for (const r of rows) {
      const res = await pg.query(
        `INSERT INTO app.harness_crash_reports (user_id, digest, kind, headline, signature, app_version,
           app_build, os_version, device_type, crash_count, hang_count, payload)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
         ON CONFLICT (user_id, digest) DO NOTHING`,
        [userId, r.digest, r.kind, r.headline, r.signature, r.appVersion, r.appBuild, r.osVersion,
          r.deviceType, r.crashCount, r.hangCount, r.payload]
      );
      stored += res.rowCount ?? 0;
    }
    return stored;
  });

const json = (value: unknown, status = 200): Response =>
  new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });

/** `POST /diagnostics/crash-reports`, after the bearer check; null for any other path. */
export const crashReportRoute = async (
  request: Request,
  env: PgEnv,
  parts: string[],
  userId: string
): Promise<Response | null> => {
  if (parts[0] !== "diagnostics" || parts[1] !== "crash-reports" || parts.length !== 2) return null;
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const declared = Number(request.headers.get("content-length") ?? 0);
  if (declared > MAX_CRASH_UPLOAD_BYTES) return json({ error: "too_large" }, 413);
  const reports = parseUpload(await request.text());
  if (!Array.isArray(reports)) return json({ error: reports.error }, reports.status);
  if (!env.HYPERDRIVE) return json({ error: "unavailable" }, 503);
  try {
    const rows = await Promise.all(reports.map(summarize));
    const stored = await storeCrashReports(env, userId, rows);
    return json({ ok: true, received: rows.length, stored });
  } catch (err) {
    console.error(JSON.stringify({ event: "crash_reports_error", error: String(err) }));
    return json({ error: "store_failed" }, 503);
  }
};

/** The account purge: every report this person's phones sent. */
export const deleteCrashReports = (env: PgEnv, userId: string): Promise<void> =>
  withPg(env, async (pg) => {
    await pg.query("DELETE FROM app.harness_crash_reports WHERE user_id = $1", [userId]);
  });
