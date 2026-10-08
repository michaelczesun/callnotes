import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("callnotes_ui", ROOT / "callnotes-ui.py")
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)

class NotificationTests(unittest.TestCase):
    def test_english_ui_is_independent_of_german_transcription(self):
        self.assertEqual(ui.resolve_language({"uiLanguage": "en", "language": "de"}, None, ["de-DE"]), "en")
        self.assertEqual(ui.phase("transcribe", "en"), "Transcribing…")

    def test_override_and_system_language(self):
        self.assertEqual(ui.resolve_language({"uiLanguage": "de"}, "en", ["de"]), "en")
        self.assertEqual(ui.resolve_language({"uiLanguage": "en"}, "de-AT", ["en"]), "de")
        self.assertEqual(ui.resolve_language({"uiLanguage": "system"}, None, ["de-DE"]), "de")
        self.assertEqual(ui.resolve_language({}, None, ["pt-PT", "de-DE"]), "en")
        self.assertEqual(ui.resolve_language({}, None, []), "en")

    def test_progress_pairs(self):
        self.assertEqual(ui.phase("speakers", "en"), "Detecting speakers…")
        self.assertEqual(ui.phase("summary", "en"), "AI summary…")
        self.assertEqual(ui.phase("archive", "en"), "Archiving & delivery…")
        self.assertEqual(ui.phase("transcribe", "de"), "Transkription läuft…")

    def test_completion_does_not_echo_german_note_title_or_filename(self):
        title, body = ui.notification("complete", "en", ["WhatsApp", "25", "2"])
        self.assertEqual(title, "Call note ready")
        self.assertEqual(body, "Call via WhatsApp (25 min). 2 speakers; assign names in CallNotes.")
        self.assertEqual(ui.notification("complete", "en", ["Zoom", "1", "1"])[1], "Call via Zoom (1 min).")

    def test_failure_messages(self):
        self.assertEqual(ui.failure("model", "en", ""), "Whisper model missing (whisperModel): not configured")
        self.assertEqual(ui.failure("tracks", "en"), "Both audio tracks are empty or could not be transcribed.")
        self.assertEqual(ui.failure("merge", "en"), "The merged transcript is empty.")
        self.assertEqual(ui.notification("failed", "en", ["Both audio tracks are empty or could not be transcribed.", "/tmp/failed"]),
                         ("Call processing failed", "Both audio tracks are empty or could not be transcribed. Audio saved in /tmp/failed."))

    def test_summary_and_expired_login_notifications(self):
        self.assertEqual(ui.notification("summary", "en", ["failed", ""])[1],
                         "Summary generation failed. The note was saved without a summary.")
        self.assertEqual(ui.notification("summary", "en", ["login", ""])[1],
                         "Claude login expired; sign in again by running 'claude' in Terminal. The note was saved without a summary.")
        self.assertEqual(ui.notification("summary", "en", ["login", "fixture-model"])[1],
                         "Claude login expired; sign in again by running 'claude' in Terminal. A fallback summary was created using fixture-model.")

    def test_german_notifications_remain_supported(self):
        self.assertEqual(ui.notification("complete", "de", ["WhatsApp", "25", "2"])[0], "Anruf-Notiz fertig")
        self.assertIn("Stimmen", ui.notification("complete", "de", ["WhatsApp", "25", "2"])[1])
        self.assertEqual(ui.failure("model", "de", ""), "Whisper-Modell fehlt (config 'whisperModel'): nicht gesetzt")

    def test_cli_emits_shell_safe_values(self):
        result = subprocess.check_output(["python3", str(ROOT / "callnotes-ui.py"), "--language", "en", "notify", "complete", "WhatsApp $(false) 'quoted'", "25", "2"], text=True)
        parsed = subprocess.check_output(["/bin/bash", "-c", result + '\nprintf "%s\\n%s" "$NOTIFY_TITLE" "$NOTIFY_BODY"'], text=True)
        self.assertEqual(parsed, "Call note ready\nCall via WhatsApp $(false) 'quoted' (25 min). 2 speakers; assign names in CallNotes.")

    def test_real_failure_pipeline_captures_english_notification(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            rec = base / "rec" / "2026-10-08_120000_whatsapp"
            rec.mkdir(parents=True)
            cfg = base / "config.json"
            cfg.write_text(json.dumps({"uiLanguage": "en", "language": "de", "outDir": str(base),
                                       "transcriber": "local", "whisperModel": str(base / "missing.bin"),
                                       "groqApiKey": "fixture", "ntfyUrl": "https://notification.invalid", "summarizer": "off"}))
            capture = base / "notification.txt"
            env = dict(os.environ, CALLNOTES_CONFIG=str(cfg), CALLNOTES_CAPTURE=str(capture))
            env.pop("CALLNOTES_LANG", None)
            # Export a local curl function into the script: no network calls occur.
            harness = 'curl() { printf "%s\\n" "$@" > "$CALLNOTES_CAPTURE"; }; export -f curl; exec /bin/bash "$1" "$2"'
            result = subprocess.run(["/bin/bash", "-c", harness, "fixture", str(ROOT / "process-call.sh"), str(rec)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Title: Call processing failed", capture.read_text())
            self.assertIn("Whisper model missing (whisperModel)", capture.read_text())
            self.assertNotIn("Anruf", capture.read_text())
            self.assertTrue((base / "failed" / rec.name).is_dir())
            self.assertEqual(json.loads(cfg.read_text())["language"], "de")

    def test_displayed_speaker_translation_keeps_assignment_keys_valid(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            cfg = base / "config.json"
            cfg.write_text(json.dumps({"notesDir": str(base), "audioDir": str(base), "mirrorDir": ""}))
            note = base / "note.md"
            note.write_text("# Deutsche Überschrift\nSprecher 1: Hallo.\nSprecher 10: Guten Tag.\n")
            pending = base / "pending.json"
            pending.write_text(json.dumps({"note": str(note), "speakers": []}))
            result = subprocess.run(["/bin/bash", str(ROOT / "apply-speakers.sh"), str(pending), "Sprecher 1=Alice;Sprecher 10=Bob"],
                                    env=dict(os.environ, CALLNOTES_CONFIG=str(cfg)), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(note.read_text(), "# Deutsche Überschrift\nAlice: Hallo.\nBob: Guten Tag.\n")

if __name__ == "__main__":
    unittest.main()
