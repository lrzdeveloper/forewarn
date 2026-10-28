#!/usr/bin/env python3
"""Fails when a string the app shows lacks a translation in any language Forewarn offers.

Usage: l10n-check.py <exported .xliff>. The .xliff (from `xcodebuild -exportLocalizations`) lists every string the
code uses now; App/Language.swift lists the languages; App/Localizable.xcstrings holds the translations.
"""
import json
import re
import sys
import xml.etree.ElementTree as ET

NS = {"x": "urn:oasis:names:tc:xliff:document:1.2"}
languages = re.findall(r'\("([a-zA-Z-]+)", "', open("App/Language.swift").read())
required = [code for code in languages if code != "en"]
catalog = json.load(open("App/Localizable.xcstrings"))["strings"]
keys = [
    unit.get("id")
    for file in ET.parse(sys.argv[1]).getroot().findall("x:file", NS)
    if "InfoPlist" not in file.get("original")
    for unit in file.findall(".//x:trans-unit", NS)
]
missing = {}
for key in keys:
    localizations = catalog.get(key, {}).get("localizations", {})
    for code in required:
        unit = localizations.get(code, {}).get("stringUnit", {})
        if unit.get("state") != "translated" or not unit.get("value"):
            missing.setdefault(code, []).append(key)
if missing:
    for code, absent in sorted(missing.items()):
        print(f"{code}: {len(absent)} missing, e.g. {absent[:3]}")
    sys.exit("Translate every new string into every language before pushing.")
print(f"l10n: {len(keys)} strings in {len(required)} languages besides English, all translated")
