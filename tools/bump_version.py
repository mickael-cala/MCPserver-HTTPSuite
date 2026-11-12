#!/usr/bin/env python3
# ============================================================================
#  bump_version.py - Bump de version depuis une source unique.
#  Met a jour G_ServerVersion = "X.Y.Z" dans tous les src/*.pb.
#
#  Usage :
#    python tools/bump_version.py 2.1.0           # applique
#    python tools/bump_version.py 2.1.0 --check   # affiche sans modifier
#
#  Sort avec le code 1 si aucun fichier n'a ete modifie (version deja
#  appliquee ou motif absent d'un fichier attendu).
# ============================================================================
import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2 or not re.match(r"^\d+\.\d+\.\d+$", sys.argv[1]):
        print("Usage : python tools/bump_version.py X.Y.Z [--check]")
        return 1
    version = sys.argv[1]
    check = "--check" in sys.argv

    root = Path(__file__).resolve().parent.parent / "src"
    changed = []
    untouched = []
    for pb in sorted(root.glob("*.pb")):
        text = pb.read_text(encoding="utf-8", errors="replace")
        new, n = re.subn(
            r'(G_ServerVersion\s*=\s*")[^"]+(")',
            rf"\g<1>{version}\g<2>",
            text,
        )
        if n == 0:
            untouched.append(pb.name)
            continue
        if new != text and not check:
            pb.write_text(new, encoding="utf-8", newline="\n")
        changed.append(pb.name)

    if changed:
        action = "serait modifie (--check)" if check else "modifie"
        print(f"Version {version} {action} dans : " + ", ".join(changed))
    else:
        print(f"Aucun G_ServerVersion a mettre a jour (deja {version} ?)")
        return 1
    if untouched:
        print(f"Sans G_ServerVersion (ignores) : " + ", ".join(untouched))
    return 0


if __name__ == "__main__":
    sys.exit(main())
