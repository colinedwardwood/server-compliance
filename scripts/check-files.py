#!/usr/bin/env python3
"""Static checks for the Grafana and Ansible files (no network access needed).

- Recording rules and alert rules parse as YAML once the deploy-time placeholders
  (${COMPLIANCE_WINDOW}, ${COMPLIANCE_WINDOW_SECONDS}) are filled in, and no other
  ${...} placeholder is left over.
- Dashboards parse as JSON, declare their datasources in __inputs, and reference them
  only through ${DS_PROMETHEUS} / ${DS_LOKI} (no stack-specific datasource UIDs).
- SLO definitions, Ansible files and profile inputs/waivers parse.

Run from the repository root: python3 scripts/check-files.py
"""
import json
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLACEHOLDERS = {"${COMPLIANCE_WINDOW}": "13h", "${COMPLIANCE_WINDOW_SECONDS}": "46800"}
DS_PLACEHOLDERS = {"${DS_PROMETHEUS}", "${DS_LOKI}"}
# UIDs that are fine to hard-code: Grafana's built-in annotation and expression sources.
BUILTIN_UIDS = {"-- Grafana --", "grafana", "-100", "__expr__"}

errors = []


def fail(path, msg):
    errors.append(f"{path.relative_to(ROOT)}: {msg}")


def check_rules(path):
    text = path.read_text()
    for key, value in PLACEHOLDERS.items():
        text = text.replace(key, value)
    leftover = re.findall(r"\$\{[A-Z_]+\}", text)
    if leftover:
        fail(path, f"unknown placeholders {sorted(set(leftover))}")
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        fail(path, f"invalid YAML: {exc}")
        return
    if not data.get("groups"):
        fail(path, "no rule groups")


def walk_uids(node, found):
    if isinstance(node, dict):
        ds = node.get("datasource")
        if isinstance(ds, dict) and "uid" in ds:
            found.add(ds["uid"])
        for value in node.values():
            walk_uids(value, found)
    elif isinstance(node, list):
        for value in node:
            walk_uids(value, found)


def check_dashboard(path):
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        fail(path, f"invalid JSON: {exc}")
        return
    uids = set()
    walk_uids(data, uids)
    hard_coded = sorted(u for u in uids if u not in DS_PLACEHOLDERS | BUILTIN_UIDS)
    if hard_coded:
        fail(path, f"hard-coded datasource UIDs {hard_coded}; use ${{DS_PROMETHEUS}} / ${{DS_LOKI}}")
    declared = {"${" + i["name"] + "}" for i in data.get("__inputs", [])}
    missing = sorted((uids & DS_PLACEHOLDERS) - declared)
    if missing:
        fail(path, f"placeholders {missing} not declared in __inputs")


def check_yaml(path):
    try:
        list(yaml.safe_load_all(path.read_text()))
    except yaml.YAMLError as exc:
        fail(path, f"invalid YAML: {exc}")


def main():
    for path in (ROOT / "grafana-cloud/recording-rules").glob("*.yaml"):
        check_rules(path)
    for path in (ROOT / "grafana-cloud/alerts").glob("*.yaml"):
        check_rules(path)
    for path in (ROOT / "grafana-cloud/dashboards").glob("*.json"):
        check_dashboard(path)
    for path in (ROOT / "grafana-cloud/slos").glob("*.json"):
        try:
            json.loads(path.read_text())
        except json.JSONDecodeError as exc:
            fail(path, f"invalid JSON: {exc}")
    for pattern in ("ansible/**/*.yml", "ansible/**/*.yml.example", "compliance-profiles/**/*.yaml"):
        for path in ROOT.glob(pattern):
            check_yaml(path)

    if errors:
        print("check-files failed:", file=sys.stderr)
        for err in errors:
            print(f"  {err}", file=sys.stderr)
        return 1
    print("check-files passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
