/**
 * RoomStore over PostgreSQL: `app.agent_rooms`, `app.agent_room_members`,
 * `app.agent_room_messages` (migration 0020_agent_rooms). Times are unix seconds; bigints come back from `pg`
 * as strings and are narrowed here (seqs and seconds stay far below 2^53).
 */
import type { Client } from "pg";
import { withPg, type PgEnv } from "./pg";
import {
  ROOM_LIMITS,
  type InboxItem,
  type LoadedRoom,
  type MemberKey,
  type MemberRow,
  type MessageRow,
  type RoomRow,
  type RoomStore,
  type RoomSummary
} from "./room-core";

type Row = Record<string, unknown>;

const num = (v: unknown): number => Number(v);
const numOrNull = (v: unknown): number | null => (v === null || v === undefined ? null : Number(v));

const roomFrom = (r: Row): RoomRow => ({
  id: r.id as string,
  orgId: r.org_id as string,
  createdBy: r.created_by as string,
  name: r.name as string,
  kind: r.kind as RoomRow["kind"],
  parentChat: (r.parent_chat as string | null) ?? null,
  idleTtlS: numOrNull(r.idle_ttl_s),
  lastSeq: num(r.last_seq),
  createdAt: num(r.created_at),
  lastActivityAt: num(r.last_activity_at),
  archivedAt: numOrNull(r.archived_at)
});

const memberFrom = (r: Row): MemberRow => ({
  member: r.member as string,
  memberKind: r.member_kind as MemberRow["memberKind"],
  memberRef: (r.member_ref as string | null) ?? null,
  deviceId: r.device_id as string,
  role: r.role as MemberRow["role"],
  readSeq: num(r.read_seq),
  joinedAt: num(r.joined_at)
});

const messageFrom = (r: Row): MessageRow => ({
  seq: num(r.seq),
  sender: r.sender as string,
  senderDevice: r.sender_device as string,
  fromUser: r.from_user as boolean,
  kind: r.kind as MessageRow["kind"],
  toMember: (r.to_member as string | null) ?? null,
  body: r.body as string,
  replyTo: numOrNull(r.reply_to),
  mentions: (r.mentions as string[] | null) ?? [],
  hop: num(r.hop),
  createdAt: num(r.created_at)
});

const MESSAGE_COLUMNS =
  "seq, sender, sender_device, from_user, kind, to_member, body, reply_to, mentions, hop, created_at";

export class PgRoomStore implements RoomStore {
  constructor(private readonly env: PgEnv) {}

  private run<T>(fn: (client: Client) => Promise<T>): Promise<T> {
    return withPg(this.env, fn);
  }

  createRoom(room: RoomRow, owner: MemberRow): Promise<void> {
    return this.run(async (pg) => {
      await pg.query("BEGIN");
      try {
        await pg.query(
          `INSERT INTO app.agent_rooms (id, org_id, created_by, name, kind, parent_chat, idle_ttl_s,
             last_seq, created_at, last_activity_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, 0, $8, $8)`,
          [room.id, room.orgId, room.createdBy, room.name, room.kind, room.parentChat, room.idleTtlS, room.createdAt]
        );
        await this.insertMember(pg, room.id, owner);
        await pg.query("COMMIT");
      } catch (err) {
        await pg.query("ROLLBACK").catch(() => {});
        throw err;
      }
    });
  }

  private async insertMember(pg: Client, roomId: string, m: MemberRow): Promise<void> {
    await pg.query(
      `INSERT INTO app.agent_room_members (room_id, member, member_kind, member_ref, device_id, role, read_seq, joined_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       ON CONFLICT (room_id, member, device_id)
       DO UPDATE SET member_kind = excluded.member_kind, member_ref = excluded.member_ref`,
      [roomId, m.member, m.memberKind, m.memberRef, m.deviceId, m.role, m.readSeq, m.joinedAt]
    );
  }

  loadRoom(id: string): Promise<LoadedRoom | null> {
    return this.run(async (pg) => {
      const rooms = await pg.query("SELECT * FROM app.agent_rooms WHERE id = $1", [id]);
      if (rooms.rows.length === 0) return null;
      const [members, recent] = await Promise.all([
        pg.query("SELECT * FROM app.agent_room_members WHERE room_id = $1 ORDER BY joined_at, member", [id]),
        pg.query(
          `SELECT ${MESSAGE_COLUMNS} FROM app.agent_room_messages WHERE room_id = $1 ORDER BY seq DESC LIMIT $2`,
          [id, ROOM_LIMITS.ring]
        )
      ]);
      return {
        room: roomFrom(rooms.rows[0]),
        members: members.rows.map(memberFrom),
        recent: recent.rows.map(messageFrom).reverse()
      };
    });
  }

  /** One statement, so the row and the room's counters commit together
   * (the append in 0020's header). Zero rows: stale seq, archived, or gone. */
  append(roomId: string, m: MessageRow): Promise<boolean> {
    return this.run(async (pg) => {
      const res = await pg.query(
        `WITH r AS (
           UPDATE app.agent_rooms SET last_seq = $2, last_activity_at = $12
            WHERE id = $1 AND last_seq = $2 - 1 AND archived_at IS NULL
           RETURNING id)
         INSERT INTO app.agent_room_messages (room_id, seq, sender, sender_device,
           from_user, kind, to_member, body, reply_to, mentions, hop, created_at)
         SELECT r.id, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 FROM r
         RETURNING seq`,
        [roomId, m.seq, m.sender, m.senderDevice, m.fromUser, m.kind, m.toMember, m.body, m.replyTo, m.mentions, m.hop, m.createdAt]
      );
      return res.rows.length === 1;
    });
  }

  upsertMember(roomId: string, member: MemberRow): Promise<void> {
    return this.run((pg) => this.insertMember(pg, roomId, member));
  }

  removeMember(roomId: string, key: MemberKey): Promise<void> {
    return this.run(async (pg) => {
      await pg.query("DELETE FROM app.agent_room_members WHERE room_id = $1 AND member = $2 AND device_id = $3", [
        roomId,
        key.member,
        key.deviceId
      ]);
    });
  }

  setReadSeq(roomId: string, key: MemberKey, seq: number): Promise<void> {
    return this.run(async (pg) => {
      await pg.query(
        `UPDATE app.agent_room_members SET read_seq = GREATEST(read_seq, $4)
          WHERE room_id = $1 AND member = $2 AND device_id = $3`,
        [roomId, key.member, key.deviceId, seq]
      );
    });
  }

  messages(roomId: string, since: number, limit: number): Promise<MessageRow[]> {
    return this.run(async (pg) => {
      const res = await pg.query(
        `SELECT ${MESSAGE_COLUMNS} FROM app.agent_room_messages
          WHERE room_id = $1 AND seq > $2 ORDER BY seq LIMIT $3`,
        [roomId, since, limit]
      );
      return res.rows.map(messageFrom);
    });
  }

  setArchived(roomId: string, at: number | null): Promise<void> {
    return this.run(async (pg) => {
      await pg.query("UPDATE app.agent_rooms SET archived_at = $2 WHERE id = $1", [roomId, at]);
    });
  }

  destroy(roomId: string): Promise<void> {
    return this.run(async (pg) => {
      // Members and messages cascade.
      await pg.query("DELETE FROM app.agent_rooms WHERE id = $1", [roomId]);
    });
  }

  listRooms(orgId: string, who?: MemberKey): Promise<RoomSummary[]> {
    return this.run(async (pg) => {
      const res = who
        ? await pg.query(
            `SELECT r.*, (SELECT count(*) FROM app.agent_room_members c WHERE c.room_id = r.id) AS member_count,
                    (SELECT count(*) FROM app.agent_room_messages x
                      WHERE x.room_id = r.id AND x.seq > m.read_seq AND x.sender <> m.member) AS unread
               FROM app.agent_rooms r
               JOIN app.agent_room_members m ON m.room_id = r.id AND m.member = $2 AND m.device_id = $3
              WHERE r.org_id = $1
              ORDER BY r.last_activity_at DESC LIMIT 200`,
            [orgId, who.member, who.deviceId]
          )
        : await pg.query(
            `SELECT r.*, (SELECT count(*) FROM app.agent_room_members c WHERE c.room_id = r.id) AS member_count
               FROM app.agent_rooms r WHERE r.org_id = $1
              ORDER BY r.last_activity_at DESC LIMIT 200`,
            [orgId]
          );
      return res.rows.map((r: Row) => {
        const room = roomFrom(r);
        return {
          id: room.id,
          name: room.name,
          kind: room.kind,
          lastSeq: room.lastSeq,
          lastActivityAt: room.lastActivityAt,
          archivedAt: room.archivedAt,
          members: num(r.member_count),
          ...(who ? { unread: num(r.unread) } : {})
        };
      });
    });
  }

  inbox(orgId: string, who: MemberKey, limit: number): Promise<InboxItem[]> {
    return this.run(async (pg) => {
      const res = await pg.query(
        `SELECT r.id AS room_id, r.name AS room_name, ${MESSAGE_COLUMNS.split(", ").map((c) => `x.${c}`).join(", ")}
           FROM app.agent_room_members m
           JOIN app.agent_rooms r ON r.id = m.room_id AND r.org_id = $1
           JOIN app.agent_room_messages x ON x.room_id = m.room_id AND x.seq > m.read_seq
          WHERE m.member = $2 AND m.device_id = $3 AND x.sender <> m.member
            AND (x.to_member = m.member
                 OR (x.to_member IS NULL AND ('@all' = ANY (x.mentions) OR m.member = ANY (x.mentions))))
          ORDER BY x.created_at, x.seq LIMIT $4`,
        [orgId, who.member, who.deviceId, limit]
      );
      return res.rows.map((r: Row) => ({
        roomId: r.room_id as string,
        roomName: r.room_name as string,
        message: messageFrom(r)
      }));
    });
  }
}

/** The sweeper: 0020's `app.sweep_expired_agent_rooms` deletes expired
 * ephemeral rooms and returns their ids so each actor can wipe itself. */
export function sweepExpiredRooms(env: PgEnv, nowS: number, max = 500): Promise<string[]> {
  return withPg(env, async (pg) => {
    const res = await pg.query("SELECT id FROM app.sweep_expired_agent_rooms($1, $2)", [nowS, max]);
    return res.rows.map((r: Row) => r.id as string);
  });
}

/** Ephemeral rooms a chat created, deleted when that chat is archived. */
export function destroyRoomsForChat(env: PgEnv, chatId: string): Promise<string[]> {
  return withPg(env, async (pg) => {
    const res = await pg.query("SELECT id FROM app.destroy_agent_rooms_for_chat($1)", [chatId]);
    return res.rows.map((r: Row) => r.id as string);
  });
}
