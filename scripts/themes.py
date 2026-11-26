#!/usr/bin/env python3
# Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
"""Build bergr/Settings/themes.json: the terminal themes offered in Settings.

Colors come from Ghostty's theme collection (iTerm2-Color-Schemes, MIT), which `just ghostty`
fetches into vendor/ghostty/zig-pkg. Run with `just themes` after changing the list below.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GHOSTTY = ROOT / "vendor/ghostty"
OUT = ROOT / "bergr/Settings/themes.json"

# (id, name, Ghostty theme file). Popular pairs, dark first; the first of each is the default.
DARK = [
    ("bergr-dark", "Bergr Dark", None),
    ("catppuccin-mocha", "Catppuccin Mocha", "Catppuccin Mocha"),
    ("dracula", "Dracula", "Dracula"),
    ("tokyo-night", "Tokyo Night", "TokyoNight"),
    ("gruvbox-dark", "Gruvbox Dark", "Gruvbox Dark"),
    ("nord", "Nord", "Nord"),
    ("one-dark", "One Dark", "Atom One Dark"),
    ("rose-pine", "Rosé Pine", "Rose Pine"),
    ("solarized-dark", "Solarized Dark", "iTerm2 Solarized Dark"),
    ("github-dark", "GitHub Dark", "GitHub Dark Default"),
    ("kanagawa-wave", "Kanagawa Wave", "Kanagawa Wave"),
    ("everforest-dark", "Everforest Dark", "Everforest Dark Med"),
    ("miami", "Miami", None),
]
LIGHT = [
    ("bergr-light", "Bergr Light", None),
    ("catppuccin-latte", "Catppuccin Latte", "Catppuccin Latte"),
    ("tokyo-night-day", "Tokyo Night Day", "TokyoNight Day"),
    ("gruvbox-light", "Gruvbox Light", "Gruvbox Light"),
    ("nord-light", "Nord Light", "Nord Light"),
    ("one-light", "One Light", "Atom One Light"),
    ("rose-pine-dawn", "Rosé Pine Dawn", "Rose Pine Dawn"),
    ("solarized-light", "Solarized Light", "iTerm2 Solarized Light"),
    ("github-light", "GitHub Light", "GitHub Light Default"),
    ("kanagawa-lotus", "Kanagawa Lotus", "Kanagawa Lotus"),
    ("everforest-light", "Everforest Light", "Everforest Light Med"),
    ("miami-light", "Miami", None),
]

# Bergr's own: the icon's charcoal and grey, an amber cursor. Their ANSI colors are borrowed
# from One Dark / One Light, which read well on these backgrounds.
BERGR = {
    "bergr-dark": {"base": "Atom One Dark", "background": "#1f2124", "foreground": "#d9dad8",
                   "cursor": "#f2b33d", "selection": "#3a3d42"},
    "bergr-light": {"base": "Atom One Light", "background": "#ecedeb", "foreground": "#303438",
                    "cursor": "#c27c0e", "selection": "#cfd1ce"},
    # A sunset on a flat plum: pinks, violets, amber, cyan and a mint green. It also turns on the
    # app's Miami look (AppLook.swift). A custom "ansi" replaces the base theme's palette.
    # Miami's sunrise: plum on blush, a deep pink cursor; colors 1-6 read at 4.4:1 or more.
    "miami-light": {"base": "Atom One Light", "background": "#fff4f6", "foreground": "#2a1033",
                    "cursor": "#d6337f", "selection": "#f6c6dd",
                    "ansi": ["#2a1033", "#c8264f", "#1f7a55", "#9a5b00", "#3a5bc7", "#9b2fae", "#0f7f8c", "#8a7690",
                             "#5e4a66", "#e0386a", "#2a9468", "#b36b00", "#4f6fe0", "#b543c9", "#138f9e", "#b8a8be"]},
    "miami": {"base": "Atom One Dark", "background": "#22102e", "foreground": "#f4eaf7",
              "cursor": "#ff7ac6", "selection": "#4a2a5e",
              "ansi": ["#3a2348", "#ff5c8a", "#5cf2b0", "#ffc66b", "#7aa2ff", "#d77bff", "#4fe3f0", "#e6dcef",
                       "#7a6690", "#ff86a8", "#8affc9", "#ffd98f", "#a3bfff", "#e8a5ff", "#8af0f7", "#ffffff"]},
}


def themes_dir() -> Path:
    for zon in [GHOSTTY / "build.zig.zon"]:
        for h in re.findall(r'\.hash\s*=\s*"(N-V-[^"]+)"', zon.read_text()):
            path = GHOSTTY / "zig-pkg" / h
            if (path / "Dracula").is_file():
                return path
    sys.exit("Ghostty's themes are missing: run `just ghostty` first")


def parse(path: Path) -> dict:
    theme = {"ansi": [None] * 16}
    for line in path.read_text().splitlines():
        key, _, value = (part.strip() for part in line.partition("="))
        if key == "palette":
            index, _, color = value.partition("=")
            if int(index) < 16:
                theme["ansi"][int(index)] = color.strip().lower()
        elif key in ("background", "foreground"):
            theme[key] = value.lower()
        elif key == "cursor-color":
            theme["cursor"] = value.lower()
        elif key == "selection-background":
            theme["selection"] = value.lower()
    if None in theme["ansi"] or "background" not in theme or "foreground" not in theme:
        sys.exit(f"incomplete theme: {path.name}")
    return theme


def build(themes: Path) -> list:
    out = []
    for dark, entries in ((True, DARK), (False, LIGHT)):
        for id, name, source in entries:
            if source:
                theme = parse(themes / source)
            else:
                spec = BERGR[id]
                theme = parse(themes / spec["base"])
                theme.update({k: v for k, v in spec.items() if k != "base"})
            theme.setdefault("cursor", theme["foreground"])
            theme.setdefault("selection", theme["ansi"][8])
            out.append({"id": id, "name": name, "dark": dark, **theme})
    return out


themes = build(themes_dir())
OUT.write_text(json.dumps(themes, indent=1, ensure_ascii=False) + "\n")
print(f"{len(themes)} themes written to {OUT.relative_to(ROOT)}")
