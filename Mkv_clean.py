import os
import json
import subprocess
import argparse
import yaml
import csv
import unicodedata

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

def normalize_text(text):
    if not text:
        return ""
    text = text.lower()
    text = unicodedata.normalize("NFD", text)
    return "".join(c for c in text if unicodedata.category(c) != "Mn")


def match_type(rule_type, language, name):
    lang = normalize_text(language)
    name = normalize_text(name)

    if rule_type == "japanese":
        return (
            lang in ["ja", "jpn", "jp"] or
            any(x in name for x in ["japanese", "japones", "jpn", "original"])
        )

    if rule_type == "latino":
        return (
            any(x in name for x in ["latino", "latam", "latin america"]) or
            lang in ["es-419", "spa-la", "es-mx"]
        )

    if rule_type == "english":
        return (
            lang in ["en", "eng"] or
            "english" in name or "ingles" in name
        )

    if rule_type == "spa":
        return "spa" in lang or "es" in lang

    return False


# ------------------------------------------------------------
# MKVMERGE
# ------------------------------------------------------------

def get_tracks(file_path):
    result = subprocess.run(
        ["mkvmerge", "-J", file_path],
        capture_output=True,
        text=True
    )

    if result.returncode != 0:
        raise Exception(f"mkvmerge error: {result.stderr}")

    return json.loads(result.stdout)


# ------------------------------------------------------------
# CORE
# ------------------------------------------------------------

def process_file(file_path, config, execute=False, overwrite=False):
    data = get_tracks(file_path)

    audio_tracks = []
    sub_tracks = []

    for t in data.get("tracks", []):
        props = t.get("properties", {})
        track = {
            "id": t["id"],
            "type": t["type"],
            "lang": props.get("language", ""),
            "name": props.get("track_name", ""),
            "default": props.get("default_track", False)
        }

        if t["type"] == "audio":
            audio_tracks.append(track)
        elif t["type"] == "subtitles":
            sub_tracks.append(track)

    # ---------------- AUDIO ----------------
    keep_audio = []

    for rule in config["audio"]["keep"]:
        matches = [
            t for t in audio_tracks
            if match_type(rule["type"], t["lang"], t["name"])
        ]

        if not matches:
            continue

        if rule.get("default", False):
            matches = sorted(matches, key=lambda x: (not x["default"], x["id"]))
            matches = [matches[0]]

        keep_audio.extend([(m, rule) for m in matches])

    keep_audio_ids = [t[0]["id"] for t in keep_audio]

    # ---------------- SUBS ----------------
    keep_subs = []

    for rule in config["subtitles"]["keep"]:
        matches = [
            t for t in sub_tracks
            if match_type(rule["language"], t["lang"], t["name"])
        ]

        if not matches:
            continue

        if rule.get("default", False):
            matches = [matches[0]]

        keep_subs.extend([(m, rule) for m in matches])

    keep_sub_ids = [t[0]["id"] for t in keep_subs]

    # ---------------- OUTPUT ----------------
    prefix = config["output"].get("rename_prefix", "_")
    output_file = os.path.join(
        os.path.dirname(file_path),
        prefix + os.path.basename(file_path)
    )

    print(f"\nProcesando: {file_path}")
    print(f"Audio keep: {keep_audio_ids}")
    print(f"Subs keep : {keep_sub_ids}")

    if not execute:
        print("DRY RUN")
        return

    if os.path.exists(output_file) and not overwrite:
        print("SKIP: archivo ya existe")
        return

    cmd = ["mkvmerge", "-o", output_file]

    if keep_audio_ids:
        cmd += ["--audio-tracks", ",".join(map(str, keep_audio_ids))]

    if keep_sub_ids:
        cmd += ["--subtitle-tracks", ",".join(map(str, keep_sub_ids))]

    # rename + default flags
    for track, rule in keep_audio:
        if "rename" in rule:
            cmd += ["--track-name", f"{track['id']}:{rule['rename']}"]
        if rule.get("default"):
            cmd += ["--default-track-flag", f"{track['id']}:yes"]

    for track, rule in keep_subs:
        if "rename" in rule:
            cmd += ["--track-name", f"{track['id']}:{rule['rename']}"]
        if rule.get("default"):
            cmd += ["--default-track-flag", f"{track['id']}:yes"]

    cmd.append(file_path)

    subprocess.run(cmd)


# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", help="Carpeta o archivo MKV")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--overwrite", action="store_true")

    args = parser.parse_args()

    root = args.path

    yaml_path = os.path.join(root, "rules.yaml")
    if not os.path.exists(yaml_path):
        raise Exception("No se encontró rules.yaml")

    with open(yaml_path, "r", encoding="utf-8") as f:
        config = yaml.safe_load(f)

    files = []

    if os.path.isfile(root):
        files = [root]
    else:
        for r, _, f in os.walk(root):
            for file in f:
                if file.endswith(".mkv") and not file.startswith("_"):
                    files.append(os.path.join(r, file))

    for f in files:
        process_file(f, config, args.execute, args.overwrite)


if __name__ == "__main__":
    main()
