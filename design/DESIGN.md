# Jot design (locked 11 Nov 2026)

Jot is a tool: open it, see your transcripts, send one to Claude. One list, a transcript view, a listening state and a send sheet.

## Mark
- **Glyph:** a "long comma" j: round head (r 12.5) whose right edge runs tangentially into a curved tail, tilted 10° anticlockwise, the head overhanging the stem on the left. Source of truth: `design/mockups/jot-mark.js` (`JOT.shape`).
- **Icon:** two glyphs side by side make a closing quote mark ”.
  - Light: ink `#0A1620` quotes on a cyan tile (`#46DAFF` → `#18CFFF`, top to bottom).
  - Dark: cyan `#18CFFF` quotes alone on black, no tile.
  - Light and dark must always look clearly different.
- **Wordmark:** the glyph as the j (accent) plus a custom geometric "ot" (ink, stroke 13). The j–o gap equals the o–t crossbar gap (6.5 units).
  - On white: j `#00A6D6`, ot `#0A1620`.
  - On dark: j `#18CFFF`, ot white.

## Colour
| Token | Light | Dark |
|---|---|---|
| bg | `#F4F7F9` | `#05090D` |
| surface | `#FFFFFF` | `#0E161D` |
| surface 2 | `#E9EFF3` | `#16212A` |
| ink | `#0A1620` | `#E8F4F8` |
| muted | `#5E6F7C` | `#7F909C` |
| line | `#DCE4EA` | `#1C2832` |
| accent (fills) | `#18CFFF` | `#18CFFF` |
| accent text | `#007CA6` | `#18CFFF` |
| on accent | `#0A1620` | `#0A1620` |
| error | `#C2410C` | `#FF8A5B` |

Cyan is only for things you act on (Paste link, Send to Claude, toggles, progress) and for timestamps. Everything else is ink and grey.

## Type
- **Onest** for all text: titles 27/700, list titles 16/600, transcript body 16.5/1.5.
- **Martian Mono** for timestamps and durations only (about 11 pt, tracking −2%).
- Both are open-licence fonts bundled in the app.

## Wait states
Thinking orbs only: **listening** while transcribing, **searching** while fetching. On light, invert and multiply; on dark, screen with a soft round mask.

