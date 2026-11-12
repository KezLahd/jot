import Foundation
import Testing
@testable import JotCore

@Test func clockFormats() {
    #expect(Read.clock(0) == "0:00")
    #expect(Read.clock(9.7) == "0:09")
    #expect(Read.clock(245) == "4:05")
    #expect(Read.clock(3767) == "1:02:47")
}

@Test func genericTitlesFallBackToTranscript() {
    #expect(Fetcher.title(raw: "Video by jot.demo") == nil)
    #expect(Fetcher.title(raw: "How Apple designs type") == "How Apple designs type")
    let segs: [Read.Segment] = [.init(start: 0, end: 2, text: "Felt texture, fluted glass, thermal gradients, water ripples, speckled graphite,")]
    #expect(Read.title(fromOpening: segs) == "Felt texture, fluted glass, thermal gradients, water ripples…")
    #expect(Read.title(fromOpening: [.init(start: 0, end: 4, text: "Restraint is what makes a layout look designed! Try it on your very next screen.")]) == "Restraint is what makes a layout look designed!")
    #expect(Read.title(fromOpening: []) == nil)
}

@Test func classifiesLoginWalls() {
    let e = Fetcher.classify(stderr: "ERROR: [Instagram] DfX: Requested content is not available, rate-limit reached or login required. Use --cookies", site: "Instagram")
    #expect(e == .needsLogin(site: "Instagram"))
    #expect(e.errorDescription == "Instagram wanted a login for this one. Share the video instead.")
}

@Test func markdownHasHeaderAndTimestamps() {
    let r = Read(id: "x", kind: .link, source: "https://www.instagram.com/reel/JOTDEMO1/", site: "Instagram",
                 title: "22 Backgrounds", creator: nil, handle: "@jot.demo", caption: nil, duration: 26,
                 posted: nil, created: .now, language: "en", engine: "whisper.cpp", model: "ggml-small", audioFile: nil,
                 segments: [.init(start: 0, end: 3, text: "Felt texture,"), .init(start: 3.2, end: 5, text: "fluted glass.")])
    #expect(r.markdown() == "# 22 Backgrounds\n\n@jot.demo · Instagram · 0:26 · https://www.instagram.com/reel/JOTDEMO1/\n\n[0:00] Felt texture,\n[0:03] fluted glass.\n")
    #expect(r.markdown(timestamps: false).hasSuffix("Felt texture, fluted glass.\n"))
    #expect(r.wordCount == 4)
}
