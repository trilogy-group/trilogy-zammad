#!/usr/bin/env python3
"""Patch zammad-config/<env>/zammad-object-attributes.json so the three li_* business-context
fields are declared as autocompletion_ajax_external_data_source (matching the migrated live
state), and so Business Unit sorts ABOVE Product (cascade parent first).

Why this matters: configure-zammad-object-attributes.ts PUTs the whole attribute object from
this JSON on every config-touching merge. While the JSON still said data_type=input, the
auto-apply would try to revert the migrated fields back to free text (which the
data_type_must_not_change validator rejects -> failed/partial config apply).

Run: python3 scripts/patch_li_external_source_config.py
Idempotent: re-running produces no further change.
"""
import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]

# Per-env intake lookup base. local uses the dev server (self-signed -> verify_ssl false).
ENV_LOOKUP = {
    "local": "https://localhost:3000/api/v1/zammad/lookup",
    "staging": "https://staging.legal-intake.ti.trilogy.com/api/v1/zammad/lookup",
    "prod": "https://legal-intake.ti.trilogy.com/api/v1/zammad/lookup",
}

# BU must come before Product so the cascade parent is chosen first.
POSITIONS = {"li_legal_entity": 1604, "li_business_unit": 1605, "li_product": 1606}
LOOKUP_TYPE = {
    "li_legal_entity": "legal_entity",
    "li_business_unit": "business_unit",
    "li_product": "product",
}


def build_data_option(env: str, name: str) -> dict:
    base = ENV_LOOKUP[env]
    qs = f"type={LOOKUP_TYPE[name]}&query=#{{search.term}}&limit=40"
    if name == "li_product":
        # cascade: filter products by the ticket's Business Unit
        qs += "&business_unit=#{ticket.li_business_unit}"
    opt = {
        "null": True,
        "search_url": f"{base}?{qs}",
        "search_result_list_key": "result",
        "search_result_value_key": "value",
        "search_result_label_key": "label",
        "linktemplate": "",
    }
    if env == "local":
        # dev server uses a self-signed cert; Zammad's server-side fetch would refuse it.
        opt["verify_ssl"] = False
    return opt


def main() -> int:
    changed_any = False
    for env in ("local", "staging", "prod"):
        path = REPO / "zammad-config" / env / "zammad-object-attributes.json"
        if not path.exists():
            print(f"  ! {env}: {path} missing, skipped")
            continue
        doc = json.loads(path.read_text())
        changed = False
        for attr in doc.get("attributes", []):
            name = attr.get("name")
            if name not in POSITIONS or attr.get("object") != "Ticket":
                continue
            want_dt = "autocompletion_ajax_external_data_source"
            want_opt = build_data_option(env, name)
            want_pos = POSITIONS[name]
            if attr.get("data_type") != want_dt:
                attr["data_type"] = want_dt
                changed = True
            if attr.get("data_option") != want_opt:
                attr["data_option"] = want_opt
                changed = True
            if attr.get("position") != want_pos:
                attr["position"] = want_pos
                changed = True
        if changed:
            # keep the file's existing 2-space style + trailing newline
            path.write_text(json.dumps(doc, indent=2) + "\n")
            print(f"  ✓ {env}: patched")
            changed_any = True
        else:
            print(f"  = {env}: already correct")
    print("done." if changed_any else "nothing to do.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
