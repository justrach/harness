import { describe, expect, it } from "vitest";
import { PRESENCE_FRESH_MS, freshPresence, type PresenceBeat } from "./registry-presence";

const beats = (entries: Record<string, PresenceBeat>) => new Map(Object.entries(entries));

describe("freshPresence", () => {
  it("hands out recent beats with the sender's own timestamp", () => {
    const map = beats({ "dev-a": { at: 987_654, seenAt: 1_000_000 } });
    expect(freshPresence(map, 1_010_000)).toEqual({ "dev-a": 987_654 });
  });

  it("leaves out a host that stopped beating, however its clock reads", () => {
    const now = 10_000_000;
    const map = beats({
      live: { at: now - 5_000, seenAt: now - 5_000 },
      gone: { at: now - 1_000, seenAt: now - 3_600_000 }
    });
    expect(freshPresence(map, now)).toEqual({ live: now - 5_000 });
  });

  it("keeps a beat until the window closes, then drops it", () => {
    const map = beats({ dev: { at: 1, seenAt: 0 } });
    expect(freshPresence(map, PRESENCE_FRESH_MS - 1)).toEqual({ dev: 1 });
    expect(freshPresence(map, PRESENCE_FRESH_MS)).toEqual({});
  });

  it("forgets the stale entries so the map stays bounded", () => {
    const map = beats({
      a: { at: 1, seenAt: 0 },
      b: { at: 2, seenAt: 100_000 }
    });
    freshPresence(map, 100_000);
    expect([...map.keys()]).toEqual(["b"]);
  });

  it("is empty for an empty room", () => {
    expect(freshPresence(new Map(), 5)).toEqual({});
  });
});
