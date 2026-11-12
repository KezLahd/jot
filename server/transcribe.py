"""Transcribes out/source.* into out/transcript.json for Jot: {"language", "model", "segments": [{start, end, text}]}.

Lines are cut like the apps' whisper.cpp settings (about 64 characters, on word boundaries, preferring the end of a
sentence), so a cloud transcript reads the same as one made on the phone or the Mac."""
import glob
import json
import os
import sys

from faster_whisper import WhisperModel

out = sys.argv[1]
audio = next(p for p in glob.glob(f"{out}/source.*") if not p.endswith(".json"))
# The caption names the things said (design terms, places, people), which helps Whisper spell them.
hint = None
try:
    meta = json.load(open(f"{out}/source.info.json"))
    hint = " ".join((meta.get("description") or meta.get("title") or "").split())[:400] or None
except (OSError, ValueError):
    pass
# small is the quick first pass. Listen again asks for large-v3-turbo and searches harder (beam 5),
# which costs a few times the compute but hears fast, mumbled or noisy speech far better.
name = os.environ.get("WHISPER_MODEL") or "small"
careful = name != "small"
model = WhisperModel(name, device="cpu", compute_type="int8")
segments, info = model.transcribe(audio, language="en", vad_filter=True, word_timestamps=True,
                                  beam_size=5 if careful else 1, condition_on_previous_text=False, initial_prompt=hint)

lines = []
def flush(words):
    text = "".join(w.word for w in words).strip()
    if text and (not lines or lines[-1]["text"][-1:] in ".?!"):
        text = text[:1].upper() + text[1:]
    if text:
        lines.append({"start": round(words[0].start, 2), "end": round(words[-1].end, 2), "text": text})

for seg in segments:
    words = []
    for w in seg.words or []:
        length = len("".join(x.word for x in words).strip())
        if words and length + len(w.word) > 64:
            flush(words)
            words = []
        words.append(w)
        length = len("".join(x.word for x in words).strip())
        if length >= 24 and w.word.rstrip()[-1:] in ".?!":
            flush(words)
            words = []
    if words:
        flush(words)

with open(f"{out}/transcript.json", "w") as f:
    json.dump({"language": info.language, "model": f"faster-whisper-{name}", "segments": lines}, f)
print(f"{len(lines)} lines, {info.duration:.0f}s of audio")
