#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Genere tests/report.html a partir de :
    - tests/report.json (resultats d'integration par serveur, ecrit par test_mcp.py)
    - arguments : nombre d'etapes reussies / echouees de run_all

Usage :
    python tests/make_report.py <steps_ok> <steps_ko>
"""

import json
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent
REPORT_JSON = BASE / "report.json"
REPORT_HTML = BASE / "report.html"


def main():
    steps_ok = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    steps_ko = int(sys.argv[2]) if len(sys.argv) > 2 else 0

    suites = {}
    totals = {"passed": 0, "failed": 0, "skipped": 0}
    if REPORT_JSON.exists():
        try:
            data = json.loads(REPORT_JSON.read_text(encoding="utf-8"))
            suites = data.get("suites", {})
            totals = data.get("totals", totals)
        except json.JSONDecodeError:
            pass

    rows = []
    for name, stats in suites.items():
        if stats.get("skipped"):
            state = "IGNORE"
            cls = "skip"
            detail = "-"
        else:
            p = stats.get("passed", 0)
            f = stats.get("failed", 0)
            detail = f"{p} / {p + f}"
            if f:
                state, cls = "ECHEC", "ko"
            else:
                state, cls = "OK", "ok"
        rows.append(f"<tr><td>{name}</td><td class='{cls}'>{state}</td><td>{detail}</td></tr>")

    all_ok = steps_ko == 0 and totals.get("failed", 0) == 0
    title = "TOUT VERT" if all_ok else "ECHECS DETECTES"
    title_cls = "ok" if all_ok else "ko"

    html = f"""<!DOCTYPE html>
<html lang="fr"><head><meta charset="utf-8">
<title>Rapport de tests - MCPserver-HTTPSuite</title>
<style>
body {{ font-family: system-ui, sans-serif; margin: 2rem; color: #222; }}
table {{ border-collapse: collapse; margin: 1rem 0; }}
th, td {{ border: 1px solid #bbb; padding: .4rem .8rem; text-align: left; }}
th {{ background: #f0f0f0; }}
.ok {{ color: #0a7d24; font-weight: bold; }}
.ko {{ color: #b00020; font-weight: bold; }}
.skip {{ color: #8a6d00; font-weight: bold; }}
</style></head><body>
<h1>Rapport de tests</h1>
<p class="{title_cls}">{title}</p>
<p>Etapes run_all : <b>{steps_ok} reussies</b>, <b>{steps_ko} echouees</b></p>
<p>Integration : <b>{totals.get('passed', 0)} reussis</b>,
   <b>{totals.get('failed', 0)} echoues</b>,
   <b>{totals.get('skipped', 0)} ignores</b></p>
<table>
<tr><th>Serveur / suite</th><th>Etat</th><th>Tests (reussis / total)</th></tr>
{chr(10).join(rows)}
</table>
<p>Genere par <code>run_all</code> - voir aussi <code>tests/report.json</code>.</p>
</body></html>
"""
    REPORT_HTML.write_text(html, encoding="utf-8")
    print(f"Rapport HTML : {REPORT_HTML}")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
