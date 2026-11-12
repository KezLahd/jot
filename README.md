<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/wordmark-dark.svg">
    <img src="docs/wordmark-light.svg" alt="Jot" width="150">
  </picture>
</p>

<p align="center"><b>Speech into words.</b><br>
Share a reel, a video or a voice memo. Get back a clean, timestamped transcript you can search, copy or hand straight to Claude.</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-26-0A1620?style=flat-square" alt="iOS 26">
  <img src="https://img.shields.io/badge/macOS-26-0A1620?style=flat-square" alt="macOS 26">
  <img src="https://img.shields.io/badge/SwiftUI-Liquid%20Glass-18CFFF?style=flat-square&labelColor=0A1620" alt="SwiftUI, Liquid Glass">
  <img src="https://img.shields.io/badge/third--party%20Swift%20packages-0-18CFFF?style=flat-square&labelColor=0A1620" alt="No third-party Swift packages">
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/hero-dark.jpg">
  <img src="docs/hero-light.jpg" alt="Jot on iPhone: the library, a transcript and the listening screen">
</picture>

## What it does

- **Share anything with a voice in it.** An Instagram reel, a TikTok, a YouTube video, a voice memo or a file. Jot fetches it, listens and writes it down.
- **Timestamps you can tap.** Every line keeps its time, so you can jump straight to the bit you want.
- **Search everything you've ever jotted.** One search field over every transcript, with Links, Voice and Files filters.
- **Send to Claude.** One button hands the transcript to the Claude app, as text or as a file.
- **Record in the app.** Tap the mic, talk, stop. It keeps recording with the screen locked.
- **iPhone and Mac.** The library syncs through iCloud. On the Mac, Jot lives in the menu bar and does the heavy lifting.
- **System, Light or Dark.** Picked in Settings; the share sheet follows it too.

## How it works

```mermaid
flowchart LR
    A[Share sheet<br/>or Paste link] --> B{What is it?}
    B -- voice memo / file --> C[Whisper on the iPhone<br/>whisper.cpp, small q5_1]
    B -- link --> D[GitHub Actions runner<br/>yt-dlp, logged out<br/>faster-whisper]
    B -- link, cloud off --> E[Mac menu-bar worker<br/>yt-dlp + whisper.cpp]
    C --> F[(iCloud library<br/>Reads/&lt;id&gt;/read.json)]
    D -- artifact + push --> F
    E -- APNs push --> F
    F --> G[Headline<br/>Foundation Models, on device]
    G --> H[Library · Search · Send to Claude]
```

**Fetching, logged out.** Links are fetched with [yt-dlp](https://github.com/yt-dlp/yt-dlp) with no cookies and no account, so Jot only ever sees what a logged-out visitor sees. If a post wants a login, Jot says so and asks you to share the video itself.

**Three places to transcribe.**
1. **On the iPhone.** Voice memos and files run through [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (the 5-bit small model plus Silero VAD), downloaded once over Wi-Fi. Until then Apple's `SpeechTranscriber` stands in. Long jobs run as iOS 26 continued-processing tasks, so they finish after you leave the app.
2. **In the cloud.** The share extension dispatches a GitHub Actions workflow ([`server/fetch.yml`](server/fetch.yml)) in a private repo. The runner fetches the post, transcribes it with faster-whisper and sends a "Transcript ready" push. Jot collects the result the next time it opens, then deletes the run. About 40 seconds for a 26-second reel, with no Mac needed.
3. **On the Mac.** A menu-bar app watches the iCloud library for requests, does the work and pushes to the phone through APNs, straight from the Mac, with no server.

**A proofread.** An optional pass with Claude Haiku fixes misheard names and terms. It keeps what Whisper actually heard alongside, so nothing is silently rewritten ([`Cleanup.swift`](JotKit/Sources/JotCore/Cleanup.swift)).

**A headline.** Each transcript gets a short title written on device by Apple's Foundation Models, from the caption and what was said.

**No secrets in the code.** The GitHub token lives in the Keychain (shared with the share extension through the App Group). The APNs key lives in the Mac's login keychain or the runner's encrypted secrets. The Anthropic key comes from the environment or the keychain.

## The mark: a j that's also a quote mark

A closing quote mark is a round head with a tail curling down and to the left. So is a lowercase j. Jot's j is drawn as a **long comma**: the head flows straight into the tail in one outline, tilted 10°. Put one in the wordmark and it reads as a j. Put two side by side and you get ” — the app icon.

<p align="center">
  <img src="docs/icon-light.png" width="120" alt="Jot icon, light: ink quote marks on a cyan tile">
  &nbsp;&nbsp;&nbsp;
  <img src="docs/icon-dark.png" width="120" alt="Jot icon, dark: cyan quote marks on black">
  &nbsp;&nbsp;&nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/wordmark-dark.svg">
    <img src="docs/wordmark-light.svg" width="150" alt="Jot wordmark">
  </picture>
</p>

### How it got here

The app started life as **Loupe** (a jeweller's magnifier), then **Rushes** and **Safelight**, all darkroom and film names. They were too precious for a tool you use twenty times a day. **Jot** stuck: short, a verb, and it's what you do with what was said. Then the mark was worked out on a few boards, one decision at a time.

**1 · From j to ” and back.** Six glyphs, from most j to most quote mark, each tried as the icon, in the dark icon and in the wordmark. The long comma (version 4) was the only one that read clearly as both.

<img src="docs/brand/1-j-to-quote.jpg" alt="Six versions of the glyph from plain j to short quote mark">

**2 · One continuous outline, tilted.** The long comma redrawn so the head runs into the tail with no seam, then tried at 0°, 6°, 10° and 14°. At 10° it reads as ” and still stands up like a j.

<img src="docs/brand/2-long-comma.jpg" alt="The long comma at four tilts">

**3 · Spacing.** The t's crossbar reaches towards the o, so the j is pulled in to match: 6.5 units at both closest points.

<img src="docs/brand/3-spacing.jpg" alt="Spacing check on the wordmark">

**4 · Colour, where light ≠ dark.** In light mode the tile is always a bright colour; in dark mode the tile disappears and the marks glow on black, so the two modes never look alike on the home screen. Out of twelve pairs, **cyan and ink** (10) won.

<img src="docs/brand/4-colour.jpg" alt="Twelve colour pairs for the icon and wordmark">

**5 · Type.** One sans for everything, one mono just for timestamps and durations. Four pairings were tested on the real screens. **Onest and Martian Mono** shipped: a touch more technical, and the mono is wide and squarish, like a tool.

<img src="docs/brand/5-type.jpg" alt="Four type pairings in light and dark">

## Design

Jot is a tool: open it, see your transcripts, send one to Claude. Everything that isn't the words gets out of the way.

<table>
  <tr>
    <td><img src="docs/home-light.jpg" alt="Library"></td>
    <td><img src="docs/read-dark.jpg" alt="Transcript in dark mode"></td>
    <td><img src="docs/settings-light.jpg" alt="Settings"></td>
    <td><img src="docs/record-light.jpg" alt="Listening"></td>
  </tr>
</table>

- **One accent.** Cyan `#18CFFF` is only for things you act on (Paste link, Send to Claude, progress) and for timestamps. Everything else is ink and grey.
- **Two typefaces.** [Onest](https://fonts.google.com/specimen/Onest) for all the text, [Martian Mono](https://fonts.google.com/specimen/Martian+Mono) for times and durations only. Both are open-licence and bundled.
- **No containers.** Inline rows under hairlines, Liquid Glass only on the controls, and text set a step further in than the glass around it.
- **Thinking orbs for waiting.** *Listening* while transcribing, *searching* while fetching, from [ThinkingOrbsKit](https://github.com/Jakubantalik/Libraries.dev).

| Token | Light | Dark |
|---|---|---|
| Background | `#F4F7F9` | `#05090D` |
| Ink | `#0A1620` | `#E8F4F8` |
| Muted | `#5E6F7C` | `#7F909C` |
| Accent | `#18CFFF` | `#18CFFF` |
| Accent text | `#007CA6` | `#18CFFF` |

More in [`design/DESIGN.md`](design/DESIGN.md).

## The code

```
App/            SwiftUI for iPhone and Mac: library, transcript, record, settings, menu-bar worker
Brand/          Colours, type, insets, appearance
Share/          The share extension
JotKit/         Swift package: fetching, Whisper, the library, cloud dispatch, and the `jot` CLI
server/         The GitHub Actions workflow and its Python helpers (transcribe, proofread, push)
tools/          Build to a phone, upload to TestFlight, App Store Connect API helper
```

There's a command-line tool too:

```bash
swift run --package-path JotKit jot read https://www.youtube.com/watch?v=…
```

`jot setup`, `jot read <link|file>`, `jot list`, `jot find <words>` and `jot show <id>` all share the app's library.

## Build it yourself

1. Xcode 26 on macOS 26.
2. Fetch whisper.cpp (a prebuilt XCFramework, about 250 MB, kept out of git):
   ```bash
   JotKit/scripts/fetch-whisper.sh
   ```
3. Open `Jot.xcodeproj`, then change the team, the bundle IDs (`com.kezlahd.jot…`), the App Group and the iCloud container to your own.
4. Build the **Jot** scheme for iPhone or My Mac.

Cloud fetch is optional. Put [`server/fetch.yml`](server/fetch.yml) in a private repo of your own as `.github/workflows/fetch.yml`, then paste a fine-grained token (Actions read and write, that repo only) into Settings › Cloud fetch.

## Credits

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and [faster-whisper](https://github.com/SYSTRAN/faster-whisper) do the listening; [yt-dlp](https://github.com/yt-dlp/yt-dlp) does the fetching.
- [ThinkingOrbsKit](https://github.com/Jakubantalik/Libraries.dev) by Jakub Antalik (MIT), vendored unchanged in `App/ThinkingOrbsKit`.
- Onest and Martian Mono, under the SIL Open Font License.

Designed and built by [Kez](https://github.com/KezLahd) with Claude.

## Licence

[MIT](LICENSE). Take it, learn from it, build on it. The bundled fonts keep their SIL Open Font License, and ThinkingOrbsKit keeps its own MIT licence.
