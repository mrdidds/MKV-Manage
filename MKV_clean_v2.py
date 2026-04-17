import os
import json
import subprocess
import argparse
import yaml
import unicodedata
from tqdm import tqdm

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

def normalize(text):
    if not text:
        return ""
    text = text.lower()
    text = unicodedata.normalize("NFD", text)
    return "".join(c for c in text if unicodedata.category(c) != "Mn")


def match_type(rule_type, lang, name):
    lang = normalize(lang)
    name = normalize(name)

    if rule_type == "japanese":
        return lang in ["ja", "jpn", "jp"] or "jap" in name or "original" in name

    if rule_type == "latino":
        return (
            any(x in name for x in ["latino", "latam", "latin america"]) or
            lang in ["es-419", "spa-la", "es-mx"]
        )

    if rule_type == "english":
        return lang in ["en", "eng"] or "ingles" in name or "english" in name

    if rule_type == "spa":
        return "spa" in lang or lang.startswith("es")

    return False


def run_mkvmerge_json(file_path):
    result = subprocess.run(
        ["mkvmerge", "-J", file_path],
        capture_output=True,
        text=True
    )

    if result.returncode != 0:
        raise Exception(result.stderr.strip())

    return json.loads(result.stdout)


# ------------------------------------------------------------
# CORE
# ------------------------------------------------------------

def process_file(file_path, config, execute=False, overwrite=False):
    try:
        data = run_mkvmerge_json(file_path)

        audio = []
        subs = []

        for t in data.get("tracks", []):
            props = t.get("properties", {})
            track = {
                "id": t["id"],
                "lang": props.get("language", ""),
                "name": props.get("track_name", ""),
                "default": props.get("default_track", False)
            }

            if t["type"] == "audio":
                audio.append(track)
            elif t["type"] == "subtitles":
                subs.append(track)

        # -------- AUDIO --------
        keep_audio = []
        for rule in config["audio"]["keep"]:
            matches = [t for t in audio if match_type(rule["type"], t["lang"], t["name"])]

            if not matches:
                continue

            if rule.get("default"):
                matches = sorted(matches, key=lambda x: (not x["default"], x["id"]))
                matches = [matches[0]]

            keep_audio.extend([(m, rule) for m in matches])

        # -------- SUBS --------
        keep_subs = []
        for rule in config["subtitles"]["keep"]:
            matches = [t for t in subs if match_type(rule["language"], t["lang"], t["name"])]

            if not matches:
                continue

            if rule.get("default"):
                matches = [matches[0]]

            keep_subs.extend([(m, rule) for m in matches])

        if not keep_audio:
            return ("SKIP", "Sin audio válido")

        # -------- OUTPUT --------
        prefix = config["output"].get("rename_prefix", "_")
        output = os.path.join(
            os.path.dirname(file_path),
            prefix + os.path.basename(file_path)
        )

        audio_ids = [t[0]["id"] for t in keep_audio]
        sub_ids = [t[0]["id"] for t in keep_subs]

        if not execute:
            return ("DRY", f"A:{audio_ids} S:{sub_ids}")

        if os.path.exists(output) and not overwrite:
            return ("SKIP", "Ya existe")

        cmd = ["mkvmerge", "-o", output]

        if audio_ids:
            cmd += ["--audio-tracks", ",".join(map(str, audio_ids))]

        if sub_ids:
            cmd += ["--subtitle-tracks", ",".join(map(str, sub_ids))]

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

        return ("OK", f"A:{audio_ids} S:{sub_ids}")

    except Exception as e:
        return ("ERROR", str(e))


# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="MKV Cleaner Pro")
    parser.add_argument("path", help="Carpeta o archivo")
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

    print(f"\nArchivos encontrados: {len(files)}")
    print("Modo:", "EJECUCIÓN" if args.execute else "DRY RUN")
    print("-" * 40)

    for file in tqdm(files, desc="Progreso", unit="archivo"):
        status, msg = process_file(file, config, args.execute, args.overwrite)
        tqdm.write(f"[{status}] {os.path.basename(file)} → {msg}")

    print("\nProceso terminado 🚀")


if __name__ == "__main__":
    main()
