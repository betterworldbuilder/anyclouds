#!/usr/bin/env python3
"""announce.py — Jarvis-style TTS for migration monitor.
Usage: python3 announce.py "message"
Uses edge-tts en-GB-RyanNeural (British male) — closest to Jarvis/Iron Man.
Falls back to gTTS British English if edge-tts fails.
"""
import sys, os, subprocess, tempfile, asyncio

def say(text):
    full_text = f"Hello Operator Zoan. {text}"
    # Try edge-tts first — British male neural voice (Jarvis-like)
    try:
        import edge_tts
        async def _speak():
            tts = edge_tts.Communicate(full_text, voice="en-GB-RyanNeural")
            f = tempfile.NamedTemporaryFile(suffix='.mp3', delete=False)
            await tts.save(f.name)
            f.close()
            for cmd in [['paplay', f.name], ['mpg123', '-q', f.name], ['ffplay', '-nodisp', '-autoexit', f.name]]:
                try:
                    subprocess.run(cmd, check=True, capture_output=True, timeout=30)
                    break
                except Exception:
                    continue
            os.unlink(f.name)
        asyncio.run(_speak())
        return
    except Exception:
        pass
    # Fallback: gTTS British English
    try:
        from gtts import gTTS
        tts = gTTS(full_text, lang='en', tld='co.uk')
        f = tempfile.NamedTemporaryFile(suffix='.mp3', delete=False)
        tts.save(f.name)
        f.close()
        for cmd in [['paplay', f.name], ['mpg123', '-q', f.name], ['ffplay', '-nodisp', '-autoexit', f.name]]:
            try:
                subprocess.run(cmd, check=True, capture_output=True, timeout=30)
                break
            except Exception:
                continue
        os.unlink(f.name)
    except Exception as e:
        print(f"[announce] TTS failed: {e}", file=sys.stderr)

if __name__ == '__main__':
    say(' '.join(sys.argv[1:]))
