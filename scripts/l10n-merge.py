#!/usr/bin/env python3
"""Merges the translation fragments presence_app/lib/l10n/parts/<area>_<lang>.arb
into presence_app/lib/l10n/app_<lang>.arb (en, es, pt), which `flutter
gen-l10n` (l10n.yaml) turns into lib/l10n/gen/.

Each area of the app keeps its own fragment, so its strings can be edited
without touching the others'. Fails when a key is defined twice, or when
English has a key that Spanish or Portuguese lacks (or the other way round).
Run from anywhere: python3 scripts/l10n-merge.py
"""
import json
import pathlib
import sys

LANGS = ["en", "es", "pt"]
L10N = pathlib.Path(__file__).resolve().parent.parent / "presence_app" / "lib" / "l10n"


def main() -> int:
    merged = {lang: {} for lang in LANGS}
    origin = {lang: {} for lang in LANGS}
    errors = []
    for lang in LANGS:
        for part in sorted((L10N / "parts").glob(f"*_{lang}.arb")):
            data = json.loads(part.read_text(encoding="utf-8"))
            for key, value in data.items():
                if key.startswith("@@"):
                    continue
                if key in merged[lang]:
                    errors.append(f"{lang}: {key} in both {origin[lang][key]} and {part.name}")
                merged[lang][key] = value
                origin[lang][key] = part.name
    messages = {lang: {k for k in merged[lang] if not k.startswith("@")} for lang in LANGS}
    for lang in LANGS[1:]:
        for key in sorted(messages["en"] - messages[lang]):
            errors.append(f"{lang}: missing {key} ({origin['en'][key]})")
        for key in sorted(messages[lang] - messages["en"]):
            errors.append(f"{lang}: {key} isn't in English ({origin[lang][key]})")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    for lang in LANGS:
        out = {"@@locale": lang}
        for key in sorted(k for k in merged[lang] if not k.startswith("@")):
            out[key] = merged[lang][key]
            if lang == "en" and f"@{key}" in merged[lang]:
                out[f"@{key}"] = merged[lang][f"@{key}"]
        (L10N / f"app_{lang}.arb").write_text(
            json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"l10n-merge: {len(messages['en'])} messages in {', '.join(LANGS)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
