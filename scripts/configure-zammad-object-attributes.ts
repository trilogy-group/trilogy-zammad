#!/usr/bin/env tsx
/**
 * Configure Object Manager Attributes (custom fields) in Zammad from local JSON file.
 *
 * IMPORTANT: This creates/updates custom field definitions.
 * After running this, you must execute database migrations in Zammad Admin UI.
 */
import { config } from "dotenv";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const envPath = process.env.ZAMMAD_ENV_DIR
  ? join(process.env.ZAMMAD_ENV_DIR, ".env")
  : resolve(__dirname, "../.env");
config({ path: envPath });

function authHeaders(token: string): HeadersInit {
  return {
    Authorization: `Token token=${token}`,
    "Content-Type": "application/json",
    Accept: "application/json",
  };
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
    throw new Error(`${label}: HTTP ${res.status} — non-JSON body`);
  }
  if (!res.ok) {
    const err = body as { error?: string; message?: string } | null;
    const msg = err?.error ?? err?.message ?? text.slice(0, 300);
    throw new Error(`${label}: HTTP ${res.status} — ${msg}`);
  }
  return body as T;
}

async function main(): Promise<void> {
  const zammadUrl = process.env.ZAMMAD_URL?.replace(/\/+$/, "") ?? "";
  const token = process.env.ZAMMAD_TOKEN ?? "";

  if (!zammadUrl || !token) {
    console.error("Set ZAMMAD_URL and ZAMMAD_TOKEN.");
    process.exit(1);
  }

  const configPath = join(
    process.env.ZAMMAD_CONFIG_DIR || join(__dirname, "../config"),
    "zammad-object-attributes.json"
  );
  const configFile = JSON.parse(readFileSync(configPath, "utf8"));
  const attributes = configFile.attributes;

  console.log("Configuring Object Manager Attributes in Zammad...");
  console.log(`Found ${attributes.length} attributes to configure\n`);

  // Fetch existing attributes to know which to update vs create
  const existing = await fetchJson<
    Array<{
      id: number;
      name: string;
      object: string;
      data_option?: Record<string, unknown>;
    }>
  >(
    `${zammadUrl}/api/v1/object_manager_attributes`,
    { headers: authHeaders(token) },
    "GET /api/v1/object_manager_attributes"
  );

  const existingMap = new Map(
    existing.map((attr) => [`${attr.object}:${attr.name}`, attr.id])
  );

  // Live data_option per attribute, so we can carry forward SECRETS that must not
  // live in git (see SECRET_DATA_OPTION_KEYS below).
  const existingDataOptions = new Map(
    existing.map((attr) => [`${attr.object}:${attr.name}`, attr.data_option ?? {}])
  );

  // data_option keys that are credentials: they are deliberately absent from the
  // committed JSON, so a verbatim PUT would WIPE them on the live attribute and
  // silently break the field (e.g. an external-data-source dropdown would start
  // getting 401 from the intake API). Carry the live value forward instead.
  const SECRET_DATA_OPTION_KEYS = [
    "bearer_token_auth",
    "basic_auth_username",
    "basic_auth_password",
  ] as const;

  const withPreservedSecrets = (attr: {
    object: string;
    name: string;
    data_option?: Record<string, unknown>;
  }) => {
    const live = existingDataOptions.get(`${attr.object}:${attr.name}`);
    if (!live || !attr.data_option) return attr;

    const preserved: Record<string, unknown> = { ...attr.data_option };
    let carried = 0;
    for (const key of SECRET_DATA_OPTION_KEYS) {
      // only carry forward when the config omits it AND the live side has one
      if (preserved[key] === undefined && live[key] !== undefined && live[key] !== "") {
        preserved[key] = live[key];
        carried += 1;
      }
    }
    if (carried === 0) return attr;

    console.log(
      `    ↳ ${attr.name}: preserved ${carried} secret data_option key(s) from live`
    );
    return { ...attr, data_option: preserved };
  };

  let created = 0;
  let updated = 0;
  let unchanged = 0;

  for (const attr of attributes) {
    const key = `${attr.object}:${attr.name}`;
    const existingId = existingMap.get(key);

    try {
      if (existingId) {
        // Update existing attribute
        await fetchJson(
          `${zammadUrl}/api/v1/object_manager_attributes/${existingId}`,
          {
            method: "PUT",
            headers: authHeaders(token),
            body: JSON.stringify(withPreservedSecrets(attr)),
          },
          `PUT /api/v1/object_manager_attributes/${existingId} (${attr.name})`
        );
        console.log(`  ✓ ${attr.name}: updated`);
        updated++;
      } else {
        // Create new attribute
        await fetchJson(
          `${zammadUrl}/api/v1/object_manager_attributes`,
          {
            method: "POST",
            headers: authHeaders(token),
            body: JSON.stringify(attr),
          },
          `POST /api/v1/object_manager_attributes (${attr.name})`
        );
        console.log(`  ✓ ${attr.name}: created`);
        created++;
      }
    } catch (error: any) {
      if (error.message.includes("unchanged")) {
        console.log(`  - ${attr.name}: unchanged`);
        unchanged++;
      } else {
        console.error(`  ✗ ${attr.name}: ${error.message}`);
      }
    }
  }

  console.log("\n" + "=".repeat(60));
  console.log(`✅ Object Manager Configuration Complete`);
  console.log(`   Created: ${created}`);
  console.log(`   Updated: ${updated}`);
  console.log(`   Unchanged: ${unchanged}`);
  console.log("=".repeat(60));

  if (created > 0 || updated > 0) {
    console.log("\n⚠️  IMPORTANT: Database Migration Required!");
    console.log("   Go to: Admin → Objects → Migrations");
    console.log(
      "   Click 'Execute Migrations' to apply changes to the database"
    );
    console.log("   Without migration, the fields won't appear in the UI.");
  }
}

main().catch((e: unknown) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
