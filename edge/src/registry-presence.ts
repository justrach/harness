/**
 * Registry presence — the memory-only beat map behind RegistryRoom.
 *
 * Clients treat every beat they are handed as "just received" (a phone stamps
 * its own receive time), so a beat from a device that left an hour ago must
 * never ride a state frame. The room therefore remembers WHEN IT HEARD each
 * beat and only hands out the recent ones. `at` is passed through untouched:
 * it is the sender's clock, and the desktop engine reads it as an epoch.
 */

/** Beats come every 15s; a client whose beats stop for this long is gone.
 * Matches PRESENCE_FRESH_MS in crates/engine/src/workspace_host.rs. */
export const PRESENCE_FRESH_MS = 45_000;

export interface PresenceBeat {
  /** The sender's own timestamp (epoch ms), forwarded as-is. */
  at: number;
  /** Server clock when the beat arrived (epoch ms). */
  seenAt: number;
}

/** Beats heard within `windowMs` of `now`, as device → `at`. Older entries are
 * dropped from `beats`, so the map cannot grow with every device ever seen. */
export function freshPresence(
  beats: Map<string, PresenceBeat>,
  now: number,
  windowMs: number = PRESENCE_FRESH_MS
): Record<string, number> {
  const fresh: Record<string, number> = {};
  for (const [device, beat] of beats) {
    if (now - beat.seenAt < windowMs) {
      fresh[device] = beat.at;
    } else {
      beats.delete(device);
    }
  }
  return fresh;
}
