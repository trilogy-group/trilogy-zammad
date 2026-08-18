/**
 * Apply declarative Zammad overviews via REST API.
 *
 * Prerequisites:
 *   - ZAMMAD_URL, ZAMMAD_TOKEN (admin token with admin.overview permission)
 *
 * Usage:
 *   npm run zammad:configure-overviews
 *
 * Options:
 *   DELETE_UNLISTED_OVERVIEWS=1 — Delete overviews not in config (dangerous!)
 */
import { config } from "dotenv";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";

config({ path: resolve(dirname(fileURLToPath(import.meta.url)), "../.env") });

const __dirname = dirname(fileURLToPath(import.meta.url));

const overviewSchema = z.object({
  name: z.string(),
  role_ids: z.array(z.number()),
  condition: z.record(z.string(), z.any()),
  order: z.object({
    by: z.string(),
    direction: z.string(),
  }),
  view: z.record(z.string(), z.any()),
  active: z.boolean(),
  prio: z.number().optional(),
  // Grouping fields — must be in the schema so the config value (null = no
  // grouping) is actually sent in the PUT body. Without these, zod strips them
  // and the live overview's group_by is never overwritten (drift bug: config
  // said null but live prod had group_by='owner' for months).
  group_by: z.string().nullable().optional(),
  group_direction: z.string().nullable().optional(),
});

const configSchema = z.object({
  overviews: z.array(overviewSchema),
});

type Overview = z.infer<typeof overviewSchema>;
type ZammadOverview = Overview & { id: number };

function authHeaders(token: string): HeadersInit {
  return {
    Authorization: `Token token=${token}`,
    "Content-Type": "application/json",
  };
}

function sameValue(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (
    typeof a === "object" &&
    a !== null &&
    typeof b === "object" &&
    b !== null
  ) {
    try {
      return JSON.stringify(a) === JSON.stringify(b);
    } catch {
      return false;
    }
  }
  return false;
}

function differs(existing: ZammadOverview, desired: Overview): boolean {
  const keys: (keyof Overview)[] = Object.keys(desired) as (keyof Overview)[];
  for (const key of keys) {
    if (!sameValue(existing[key], desired[key])) {
      return true;
    }
  }
  return false;
}

async function fetchJson<T>(
  url: string,
  init: RequestInit,
  label: string
): Promise<T> {
  const res = await fetch(url, init);
  const text = await res.text();
  let body: unknown;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    throw new Error(
      `${label}: HTTP ${res.status} — non-JSON: ${text.slice(0, 200)}`
    );
  }
  if (!res.ok) {
    const err = body as { error?: string } | null;
    throw new Error(
      `${label}: HTTP ${res.status} — ${err?.error ?? text.slice(0, 300)}`
    );
  }
  return body as T;
}

async function main(): Promise<void> {
  const zammadUrl = process.env.ZAMMAD_URL?.replace(/\/+$/, "") ?? "";
  const token = process.env.ZAMMAD_TOKEN ?? "";
  const deleteUnlisted = process.env.DELETE_UNLISTED_OVERVIEWS === "1";

  if (!zammadUrl || !token) {
    console.error("Set ZAMMAD_URL and ZAMMAD_TOKEN.");
    process.exit(1);
  }

  const configPath = process.argv[2]
    ? resolve(process.cwd(), process.argv[2])
    : join(
        process.env.ZAMMAD_CONFIG_DIR || join(__dirname, "../config"),
        "zammad-overviews.json"
      );

  let raw: string;
  try {
    raw = readFileSync(configPath, "utf8");
  } catch {
    console.error(`Cannot read: ${configPath}`);
    process.exit(1);
  }

  const parsed = configSchema.safeParse(JSON.parse(raw));
  if (!parsed.success) {
    console.error("Invalid config:", parsed.error.flatten());
    process.exit(1);
  }

  const desired = parsed.data.overviews;

  const existing = await fetchJson<ZammadOverview[]>(
    `${zammadUrl}/api/v1/overviews`,
    { headers: authHeaders(token) },
    "GET /api/v1/overviews"
  );

  const byName = new Map(existing.map((o) => [o.name.toLowerCase(), o]));
  const processedIds = new Set<number>();

  for (const overview of desired) {
    const existingOverview = byName.get(overview.name.toLowerCase());

    if (!existingOverview) {
      const created = await fetchJson<ZammadOverview>(
        `${zammadUrl}/api/v1/overviews`,
        {
          method: "POST",
          headers: authHeaders(token),
          body: JSON.stringify(overview),
        },
        `POST /api/v1/overviews (${overview.name})`
      );
      console.log(`  ${overview.name}: created (id=${created.id})`);
      processedIds.add(created.id);
      continue;
    }

    processedIds.add(existingOverview.id);

    if (!differs(existingOverview, overview)) {
      console.log(`  ${overview.name}: unchanged`);
      continue;
    }

    await fetchJson<ZammadOverview>(
      `${zammadUrl}/api/v1/overviews/${existingOverview.id}`,
      {
        method: "PUT",
        headers: authHeaders(token),
        body: JSON.stringify({ id: existingOverview.id, ...overview }),
      },
      `PUT /api/v1/overviews/${existingOverview.id} (${overview.name})`
    );
    console.log(`  ${overview.name}: updated`);
  }

  if (deleteUnlisted) {
    for (const overview of existing) {
      if (!processedIds.has(overview.id)) {
        await fetchJson<void>(
          `${zammadUrl}/api/v1/overviews/${overview.id}`,
          { method: "DELETE", headers: authHeaders(token) },
          `DELETE /api/v1/overviews/${overview.id} (${overview.name})`
        );
        console.log(`  ${overview.name}: deleted (not in config)`);
      }
    }
  }

  console.log("Done.");
}

main().catch((e: unknown) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
