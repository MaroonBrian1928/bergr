#!/usr/bin/env python3
"""Collect the licenses of everything shipped inside Bergr into bergr/Licenses/licenses.json.

Run with `just licenses` after changing Swift packages or the Ghostty pin. Needs resolved
packages (`just build`) and the Ghostty dependencies (`just ghostty`).
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECKOUTS = [ROOT / ".build/xcode/SourcePackages/checkouts", ROOT / "HerdrKit/.build/checkouts"]
GHOSTTY = ROOT / "vendor/ghostty"
EXTRA = ROOT / "scripts/licenses"
OUT = ROOT / "bergr/Licenses/licenses.json"


def checkout(name: str) -> Path:
    for base in CHECKOUTS:
        if (base / name).is_dir():
            return base / name
    sys.exit(f"missing package checkout {name}: build the app first (just build)")


def zig_pkg(zon: Path, name_hint: str) -> Path:
    """The zig-pkg directory of a Ghostty dependency, found by the hash in its build.zig.zon."""
    text = zon.read_text()
    hashes = re.findall(r'\.hash\s*=\s*"([^"]+)"', text)
    for h in hashes:
        if h.startswith(name_hint) or (name_hint == "" and h.startswith("N-V-")):
            path = GHOSTTY / "zig-pkg" / h
            if path.is_dir():
                return path
    sys.exit(f"missing Ghostty dependency from {zon}: run just ghostty first")


def read(*paths: Path) -> str:
    return "\n\n".join(p.read_text().strip() for p in paths)


def swift(name: str, url: str, license: str, *files: str) -> dict:
    d = checkout(name)
    return {"name": name, "url": url, "license": license, "text": read(*(d / f for f in files))}


uucode = zig_pkg(GHOSTTY / "build.zig.zon", "uucode-")
highway = zig_pkg(GHOSTTY / "pkg/highway/build.zig.zon", "")
wuffs = zig_pkg(GHOSTTY / "pkg/wuffs/build.zig.zon", "")

licenses = [
    # Bergr is a modified Hirte: its notice and the Apache license it's under come first.
    {"name": "Hirte", "url": "https://github.com/glattziehen/hirte", "license": "Apache-2.0",
     "text": "Copyright 2026 Pavel Zwerschke\n\nBergr is a modified version of Hirte, licensed under the "
             "Apache License, Version 2.0.\n\n" + read(ROOT / "NOTICE", ROOT / "LICENSE")},
    {"name": "Ghostty", "url": "https://github.com/ghostty-org/ghostty", "license": "MIT",
     "text": read(GHOSTTY / "LICENSE")},
    {"name": "Zig standard library", "url": "https://github.com/ziglang/zig", "license": "MIT",
     "text": read(EXTRA / "zig.txt")},
    {"name": "uucode", "url": "https://github.com/jacobsandlund/uucode", "license": "MIT",
     "text": read(uucode / "LICENSE.md")},
    {"name": "Highway", "url": "https://github.com/google/highway", "license": "Apache-2.0 or BSD-3-Clause",
     "text": read(highway / "LICENSE-BSD3")},
    {"name": "simdutf", "url": "https://github.com/simdutf/simdutf", "license": "Apache-2.0 or MIT",
     "text": read(EXTRA / "simdutf.txt")},
    {"name": "Wuffs", "url": "https://github.com/google/wuffs", "license": "Apache-2.0 or MIT",
     "text": read(wuffs / "LICENSE-MIT")},
    {"name": "JetBrains Mono", "url": "https://github.com/JetBrains/JetBrainsMono", "license": "OFL-1.1",
     "text": read(EXTRA / "jetbrains-mono.txt")},
    {"name": "Comic Mono", "url": "https://github.com/dtinth/comic-mono-font", "license": "MIT",
     "text": read(EXTRA / "comic-mono.txt")},
    {"name": "Terminal color themes (iTerm2-Color-Schemes)", "url": "https://github.com/mbadolato/iTerm2-Color-Schemes",
     "license": "MIT", "text": "Catppuccin, Dracula, Tokyo Night, Gruvbox, Nord, One, Rosé Pine, Solarized, GitHub, "
     "Kanagawa and Everforest colors, as collected by iTerm2-Color-Schemes and shipped with Ghostty. "
     "Each theme belongs to its authors.\n\n" + read(EXTRA / "terminal-themes.txt")},
    swift("Citadel", "https://github.com/orlandos-nl/Citadel", "MIT", "LICENSE"),
    swift("BigInt", "https://github.com/attaswift/BigInt", "MIT", "LICENSE.md"),
    swift("swift-nio", "https://github.com/apple/swift-nio", "Apache-2.0", "NOTICE.txt", "LICENSE.txt"),
    swift("swift-nio-ssh", "https://github.com/apple/swift-nio-ssh", "Apache-2.0", "LICENSE.txt"),
    swift("swift-nio-transport-services", "https://github.com/apple/swift-nio-transport-services", "Apache-2.0", "LICENSE.txt"),
    swift("swift-crypto", "https://github.com/apple/swift-crypto", "Apache-2.0", "NOTICE.txt", "LICENSE.txt"),
    swift("swift-asn1", "https://github.com/apple/swift-asn1", "Apache-2.0", "NOTICE.txt", "LICENSE.txt"),
    swift("swift-atomics", "https://github.com/apple/swift-atomics", "Apache-2.0", "LICENSE.txt"),
    swift("swift-collections", "https://github.com/apple/swift-collections", "Apache-2.0", "LICENSE.txt"),
    swift("swift-log", "https://github.com/apple/swift-log", "Apache-2.0", "NOTICE.txt", "LICENSE.txt"),
    swift("swift-system", "https://github.com/apple/swift-system", "Apache-2.0", "LICENSE.txt"),
]

# Every resolved Swift package must be listed above, so a new dependency can't slip in unnoticed.
resolved = json.loads((ROOT / "HerdrKit/Package.resolved").read_text())
names = {Path(p["location"]).name.removesuffix(".git").lower() for p in resolved["pins"]}
missing = names - {l["name"].lower() for l in licenses}
if missing:
    sys.exit(f"add licenses for: {', '.join(sorted(missing))}")

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(licenses, indent=2, ensure_ascii=False) + "\n")
print(f"{len(licenses)} licenses written to {OUT.relative_to(ROOT)}")
