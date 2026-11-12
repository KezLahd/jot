import Testing
@testable import JotCore

@Suite struct CleanupTests {
    @Test func acceptsAMisheardWord() {
        #expect(Cleanup.isSmallFix(from: "These delete the contact form on your website.", to: "Please delete the contact form on your website."))
        #expect(Cleanup.isSmallFix(from: "comment below and I'll see you in the end.", to: "comment below and I'll send you the link."))
    }

    @Test func refusesRewritesAndNoOps() {
        #expect(!Cleanup.isSmallFix(from: "and a bunch more other bullshit.", to: "and plenty of other details."))
        #expect(!Cleanup.isSmallFix(from: "So instead, replace it", to: "So instead replace it."))
        #expect(!Cleanup.isSmallFix(from: "One simple question at a time.", to: ""))
    }

    @Test func mergeKeepsWhatWasHeard() {
        let segs = [Read.Segment(start: 0, end: 1, text: "These delete the contact form."), .init(start: 1, end: 2, text: "Fine line.")]
        let out = Cleanup.merge(segs, [0: "Please delete the contact form.", 5: "nope", 1: "Totally different words here now."])
        #expect(out[0].text == "Please delete the contact form.")
        #expect(out[0].heard == "These delete the contact form.")
        #expect(out[0].start == 0 && out[0].end == 1)
        #expect(out[1].heard == nil && out[1].text == "Fine line.")
    }
}
