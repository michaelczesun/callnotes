#!/usr/bin/env python3
"""App and notification language; transcription/note generation is independent."""
import argparse
import json
import os
import re
import shlex
import subprocess


def system_languages():
    try:
        result = subprocess.run(["/usr/bin/defaults", "read", "-g", "AppleLanguages"],
                                capture_output=True, text=True, check=True)
        return [value for line in result.stdout.splitlines()
                if re.fullmatch(r"[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]+)*", value := line.strip().strip('()," '))]
    except (OSError, subprocess.CalledProcessError):
        return []


def resolve_language(config, override=None, preferred=None):
    if override:
        return "de" if override.lower().startswith("de") else "en"
    configured = config.get("uiLanguage")
    if configured in ("en", "de"):
        return configured
    preferred = system_languages() if preferred is None else preferred
    return "de" if preferred and preferred[0].lower().startswith("de") else "en"


def choose(language, de, en):
    return de if language == "de" else en


def phase(kind, language):
    pairs = {
        "transcribe": ("Transkription läuft…", "Transcribing…"),
        "speakers": ("Sprecher-Erkennung…", "Detecting speakers…"),
        "summary": ("KI-Zusammenfassung…", "AI summary…"),
        "archive": ("Archiv & Ablage…", "Archiving & delivery…"),
    }
    return choose(language, *pairs[kind])


def failure(kind, language, context=""):
    if kind == "model":
        context = context or choose(language, "nicht gesetzt", "not configured")
        return choose(language, "Whisper-Modell fehlt (config 'whisperModel'): ", "Whisper model missing (whisperModel): ") + context
    if kind == "tracks":
        return choose(language, "Beide Spuren sind leer oder nicht transkribierbar.", "Both audio tracks are empty or could not be transcribed.")
    if kind == "merge":
        return choose(language, "Das zusammengeführte Transkript ist leer.", "The merged transcript is empty.")
    return choose(language, "Verarbeitung fehlgeschlagen. Details stehen im Verarbeitungsprotokoll.", "Processing failed. See the processing log for details.")


def localize_failure(raw, language):
    raw = raw.strip()
    for prefix in ("Whisper-Modell fehlt (config 'whisperModel'): ", "Whisper model missing (whisperModel): "):
        if raw.startswith(prefix):
            context = raw[len(prefix):]
            return failure("model", language, "" if context in ("nicht gesetzt", "not configured") else context)
    if raw in ("beide Spuren leer/nicht transkribierbar", "Beide Spuren sind leer oder nicht transkribierbar.", "Both audio tracks are empty or could not be transcribed."):
        return failure("tracks", language)
    if raw in ("Dialog-Merge leer", "Das zusammengeführte Transkript ist leer.", "The merged transcript is empty."):
        return failure("merge", language)
    return failure("unknown", language)


def notification(kind, language, args):
    if kind == "complete":
        app, minutes, speakers = args[:3]
        # Optional 4th argument: the note's own title (user content, like the transcript),
        # shown verbatim as the first line — it says at a glance what the call was about.
        note_title = args[3].strip() if len(args) > 3 else ""
        if app in ("unbekannt", "unknown"):
            app = choose(language, "unbekannte App", "unknown app")
        title = choose(language, "Anruf-Notiz fertig", "Call note ready")
        body = choose(language, f"Anruf via {app} ({minutes} Min.).", f"Call via {app} ({minutes} min).")
        if int(speakers) > 1:
            body += choose(language, f" {speakers} Stimmen; Namen in CallNotes zuordnen.", f" {speakers} speakers; assign names in CallNotes.")
        if note_title:
            body = f"{note_title}\n{body}"
        return title, body
    if kind == "failed":
        reason, path = args
        title = choose(language, "Anruf-Verarbeitung fehlgeschlagen", "Call processing failed")
        body = localize_failure(reason, language) + choose(language, f" Audio liegt in {path}.", f" Audio saved in {path}.")
        return title, body
    if kind == "summary":
        reason, model = args
        body = (choose(language, "Claude-Login abgelaufen; im Terminal mit 'claude' erneut anmelden.",
                       "Claude login expired; sign in again by running 'claude' in Terminal.") if reason == "login"
                else choose(language, "Zusammenfassung fehlgeschlagen.", "Summary generation failed."))
        body += (choose(language, f" Eine Fallback-Zusammenfassung wurde mit {model} erstellt.", f" A fallback summary was created using {model}.") if model
                 else choose(language, " Die Notiz wurde ohne Zusammenfassung gespeichert.", " The note was saved without a summary."))
        return "CallNotes", body
    raise ValueError("Unknown notification kind: " + kind)


def shell_values(values):
    return "\n".join(f"{key}={shlex.quote(str(value))}" for key, value in values.items())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config")
    parser.add_argument("--language", choices=("en", "de"))
    parser.add_argument("command", choices=("shell-strings", "phase", "failure", "notify"))
    parser.add_argument("arguments", nargs="*")
    args = parser.parse_args()
    config = {}
    if args.config:
        with open(args.config, encoding="utf-8") as source:
            config = json.load(source)
    language = args.language or resolve_language(config, os.environ.get("CALLNOTES_LANG"))
    if args.command == "shell-strings":
        print(shell_values({"UI_LANGUAGE": language,
                            "T_PH_TRANS": phase("transcribe", language), "T_PH_DIA": phase("speakers", language),
                            "T_PH_AI": phase("summary", language), "T_PH_STORE": phase("archive", language),
                            "T_FAIL_TRACKS": failure("tracks", language), "T_FAIL_MERGE": failure("merge", language)}))
    elif args.command == "phase":
        print(phase(args.arguments[0], language))
    elif args.command == "failure":
        print(failure(args.arguments[0], language, args.arguments[1] if len(args.arguments) > 1 else ""))
    else:
        title, body = notification(args.arguments[0], language, args.arguments[1:])
        print(shell_values({"NOTIFY_TITLE": title, "NOTIFY_BODY": body}))


if __name__ == "__main__":
    main()
