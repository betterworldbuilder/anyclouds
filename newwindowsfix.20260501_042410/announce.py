#!/usr/bin/env python3
"""announce.py — TTS helper for migration monitor.

Examples:
  python3 announce.py "Migration finished successfully"
  python3 announce.py --voice female "UAT checks passed"

Voice selection:
  - male   -> en-GB-RyanNeural
  - female -> en-GB-SoniaNeural

Fallback:
  gTTS with British English accent when edge-tts is unavailable.
"""
import argparse
import asyncio
import os
import subprocess
import sys
import tempfile


VOICE_MAP = {
    "male": "en-GB-RyanNeural",
    "female": "en-GB-SoniaNeural",
}


def _play_audio_file(path: str) -> None:
    for cmd in (["paplay", path], ["mpg123", "-q", path], ["ffplay", "-nodisp", "-autoexit", path]):
        try:
            subprocess.run(cmd, check=True, capture_output=True, timeout=30)
            return
        except Exception:
            continue


def say(text: str, voice_gender: str = "male") -> None:
    full_text = f"Hello Operator Zoan. {text}"
    selected = VOICE_MAP.get((voice_gender or "male").lower(), VOICE_MAP["male"])

    # Try edge-tts first (British neural male/female voices).
    try:
        import edge_tts

        async def _speak() -> None:
            tts = edge_tts.Communicate(full_text, voice=selected)
            tmp = tempfile.NamedTemporaryFile(suffix=".mp3", delete=False)
            await tts.save(tmp.name)
            tmp.close()
            try:
                _play_audio_file(tmp.name)
            finally:
                if os.path.exists(tmp.name):
                    os.unlink(tmp.name)

        asyncio.run(_speak())
        return
    except Exception:
        pass

    # Fallback: gTTS British English (accent only, no gender control).
    try:
        from gtts import gTTS

        tts = gTTS(full_text, lang="en", tld="co.uk")
        tmp = tempfile.NamedTemporaryFile(suffix=".mp3", delete=False)
        tts.save(tmp.name)
        tmp.close()
        try:
            _play_audio_file(tmp.name)
        finally:
            if os.path.exists(tmp.name):
                os.unlink(tmp.name)
    except Exception as exc:
        print(f"[announce] TTS failed: {exc}", file=sys.stderr)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Speak migration status in British TTS voices.")
    parser.add_argument("message", nargs="+", help="Text to speak.")
    parser.add_argument("--voice", choices=["male", "female"], default=os.environ.get("JARVIS_VOICE_GENDER", "male"))
    return parser.parse_args()


if __name__ == "__main__":
    args = _parse_args()
    say(" ".join(args.message), voice_gender=args.voice)
