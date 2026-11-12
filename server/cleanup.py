"""Proofreads out/transcript.json with Claude Haiku: fixes only words Whisper almost certainly misheard.

The same rules as the apps (JotKit/Sources/JotCore/Cleanup.swift): a changed line keeps what Whisper wrote in
"heard", timestamps never move, and anything that looks like a rewrite rather than a word swap is thrown away.
Any failure leaves the transcript exactly as Whisper wrote it."""
import json
import os
import string
import sys

import anthropic

MODEL = "claude-haiku-5-5"

INSTRUCTIONS = """You proofread speech-to-text transcripts made by Whisper. Whisper sometimes mishears a word, \
most often at the very start of a clip or on names and jargon: "These delete the contact form" \
for "Please delete the contact form", "fluted glass" heard as "fluted class".

Fix a word only when you are confident it was misheard: the written word makes little sense where \
it is and a similar-sounding word clearly fits, or a name or term is misspelled and the caption \
shows the right spelling. Leave everything else exactly as it is: slang, swearing, filler, \
repetition, run-ons, bad grammar, and anything that already makes sense. When unsure, leave it.

Keep each line's wording apart from the fixed words. Never merge, split, reorder, summarise or \
rephrase lines, and never add punctuation that wasn't needed for the fix. Return only the lines \
you changed, each in full with its number. Return an empty list when nothing needs fixing."""

SCHEMA = {
    "type": "object",
    "properties": {
        "fixes": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"line": {"type": "integer"}, "text": {"type": "string"}},
                "required": ["line", "text"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["fixes"],
    "additionalProperties": False,
}


def words(s):
    out = (w.strip(string.punctuation + "“”‘’…") for w in s.lower().split())
    return [w for w in out if w]


def lcs(a, b):
    prev = [0] * (len(b) + 1)
    for x in a:
        cur = [0] * (len(b) + 1)
        for j, y in enumerate(b):
            cur[j + 1] = prev[j] + 1 if x == y else max(prev[j + 1], cur[j])
        prev = cur
    return prev[-1]


def small_fix(old, new):
    a, b = words(old), words(new)
    if not b or abs(len(a) - len(b)) > 2:
        return False
    changed = max(len(a), len(b)) - lcs(a, b)
    return 1 <= changed <= max(2, len(a) // 3)


def main(out):
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("No ANTHROPIC_API_KEY; leaving the transcript as Whisper wrote it")
        return
    path = f"{out}/transcript.json"
    transcript = json.load(open(path))
    segments = transcript["segments"]
    if not segments:
        return

    prompt = ""
    try:
        meta = json.load(open(f"{out}/source.info.json"))
        who = meta.get("uploader_id") or meta.get("uploader") or meta.get("channel")
        if who:
            prompt += f"Speaker: {who}\n"
        caption = " ".join((meta.get("description") or meta.get("title") or "").split())
        if caption:
            prompt += f"Caption: {caption[:1500]}\n"
    except (OSError, ValueError):
        pass
    prompt += "\nTranscript:\n" + "".join(f"{i}: {s['text']}\n" for i, s in enumerate(segments))

    try:
        response = anthropic.Anthropic().messages.create(
            model=MODEL,
            max_tokens=8000,
            system=INSTRUCTIONS,
            output_config={"effort": "low", "format": {"type": "json_schema", "schema": SCHEMA}},
            messages=[{"role": "user", "content": prompt}],
        )
        if response.stop_reason != "end_turn":
            print(f"Cleanup skipped: Claude stopped early ({response.stop_reason})")
            return
        text = next(b.text for b in response.content if b.type == "text")
        fixes = json.loads(text)["fixes"]
    except (anthropic.APIError, StopIteration, ValueError, KeyError) as e:
        print(f"Cleanup skipped: {e}")
        return

    fixed = 0
    for fix in fixes:
        i, new = fix["line"], fix["text"].strip()
        if not 0 <= i < len(segments) or "heard" in segments[i]:
            continue
        old = segments[i]["text"]
        if new != old and small_fix(old, new):
            segments[i]["heard"] = old
            segments[i]["text"] = new
            fixed += 1
    transcript["cleaned"] = MODEL
    with open(path, "w") as f:
        json.dump(transcript, f)
    print(f"Fixed {fixed} misheard line(s)")


if __name__ == "__main__":
    main(sys.argv[1])
