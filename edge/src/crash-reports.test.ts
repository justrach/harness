import { describe, expect, it } from "vitest";
import {
  MAX_CRASH_REPORTS_PER_UPLOAD,
  MAX_CRASH_UPLOAD_BYTES,
  crashReportRoute,
  parseUpload,
  summarize,
  topFrames
} from "./crash-reports";

const frame = (binaryName: string, offset: number, subFrames: unknown[] = []) => ({
  binaryUUID: "6E1F1A2B-0000-4000-8000-000000000001",
  binaryName,
  offsetIntoBinaryImage: offset,
  address: 0x100000000 + offset,
  sampleCount: 1,
  subFrames
});

// The shape MXDiagnosticPayload.jsonRepresentation() produces.
const crashPayload = (offset = 4096) => ({
  timeStampBegin: "2026-10-31 19:00:00",
  timeStampEnd: "2026-10-31 19:59:00",
  crashDiagnostics: [
    {
      version: "1.0.0",
      callStackTree: {
        callStackPerThread: true,
        callStacks: [
          { threadAttributed: false, callStackRootFrames: [frame("libsystem_kernel.dylib", 12)] },
          {
            threadAttributed: true,
            callStackRootFrames: [
              frame("libswiftCore.dylib", 900, [frame("Harness", offset, [frame("Harness", offset + 64)])])
            ]
          }
        ]
      },
      diagnosticMetaData: {
        appBuildVersion: "412",
        appVersion: "0.2.153",
        osVersion: "iPhone OS 27.0 (24A5300a)",
        deviceType: "iPhone18,2",
        exceptionType: 6,
        signal: 5,
        bundleIdentifier: "harness.codegraff.ios"
      }
    }
  ]
});

describe("crash reports: summarizing a MetricKit payload", () => {
  it("reads a crash's headline, build, device and counts", async () => {
    const row = await summarize(crashPayload());
    expect(row).toMatchObject({
      kind: "crash",
      headline: "Crash: EXC_BREAKPOINT · SIGTRAP",
      appVersion: "0.2.153",
      appBuild: "412",
      osVersion: "iPhone OS 27.0 (24A5300a)",
      deviceType: "iPhone18,2",
      crashCount: 1,
      hangCount: 0
    });
    expect(row.digest).toMatch(/^[0-9a-f]{64}$/);
    expect(row.signature).toMatch(/^[0-9a-f]{16}$/);
    expect(JSON.parse(row.payload)).toEqual(crashPayload());
  });

  it("walks the crashed thread from its top frame down", () => {
    const diagnostic = crashPayload().crashDiagnostics[0] as unknown as Record<string, unknown>;
    expect(topFrames(diagnostic)).toEqual(["libswiftCore.dylib+900", "Harness+4096", "Harness+4160"]);
  });

  it("gives the same crash the same signature and a different one another", async () => {
    const a = await summarize(crashPayload());
    const b = await summarize({ ...crashPayload(), timeStampEnd: "2026-11-01 08:00:00" });
    const c = await summarize(crashPayload(8192));
    expect(b.digest).not.toBe(a.digest);
    expect(b.signature).toBe(a.signature);
    expect(c.signature).not.toBe(a.signature);
  });

  it("prefers the watchdog's own words when iOS gives them", async () => {
    const p = crashPayload();
    (p.crashDiagnostics[0].diagnosticMetaData as Record<string, unknown>).terminationReason =
      "Namespace FRONTBOARD, Code 0x8badf00d\nmore";
    expect((await summarize(p)).headline).toBe("Crash: Namespace FRONTBOARD, Code 0x8badf00d");
  });

  it("names hangs, slow launches and empty payloads", async () => {
    const hang = await summarize({ hangDiagnostics: [{ diagnosticMetaData: { hangDuration: "3.2 sec" } }] });
    expect(hang).toMatchObject({ kind: "hang", headline: "Hang (3.2 sec)", hangCount: 1, crashCount: 0 });
    const launch = await summarize({ appLaunchDiagnostics: [{ diagnosticMetaData: { launchDuration: "4 sec" } }] });
    expect(launch).toMatchObject({ kind: "launch", headline: "Slow launch (4 sec)", signature: null });
    expect(await summarize({})).toMatchObject({ kind: "other", headline: "Diagnostics", signature: null });
  });
});

describe("crash reports: the upload", () => {
  it("takes a non-empty array of objects within the limits", () => {
    expect(parseUpload(JSON.stringify([crashPayload()]))).toHaveLength(1);
    expect(parseUpload("nope")).toEqual({ error: "bad_json", status: 400 });
    expect(parseUpload("[]")).toMatchObject({ status: 400 });
    expect(parseUpload("[1]")).toMatchObject({ status: 400 });
    expect(parseUpload(JSON.stringify({ a: 1 }))).toMatchObject({ status: 400 });
    expect(parseUpload(JSON.stringify(Array(MAX_CRASH_REPORTS_PER_UPLOAD + 1).fill({})))).toMatchObject({ status: 413 });
    expect(parseUpload(" ".repeat(MAX_CRASH_UPLOAD_BYTES + 1))).toMatchObject({ status: 413 });
  });

  it("answers only its own path", async () => {
    const req = (method: string, body?: string) =>
      new Request("https://edge/diagnostics/crash-reports", { method, body });
    expect(await crashReportRoute(req("POST", "[{}]"), {}, ["diagnostics", "other"], "2")).toBeNull();
    expect(await crashReportRoute(req("POST", "[{}]"), {}, ["blob", "x", "y"], "2")).toBeNull();
    expect((await crashReportRoute(req("GET"), {}, ["diagnostics", "crash-reports"], "2"))?.status).toBe(405);
    expect((await crashReportRoute(req("POST", "{}"), {}, ["diagnostics", "crash-reports"], "2"))?.status).toBe(400);
    // Valid, but no database configured (dev edge).
    expect((await crashReportRoute(req("POST", "[{}]"), {}, ["diagnostics", "crash-reports"], "2"))?.status).toBe(503);
  });
});
