import Testing
import FudehandCore

@Test func markdownSplitsParagraphsHeadingsAndRules() {
    let blocks = ChatMarkdown.blocks("# Title\nFirst line\nsecond line\n\n### Sub\n---\nLast")
    #expect(blocks == [
        .heading(level: 1, text: "Title"), .paragraph("First line\nsecond line"),
        .heading(level: 3, text: "Sub"), .rule, .paragraph("Last"),
    ])
    #expect(ChatMarkdown.blocks("#hashtag is not a heading") == [.paragraph("#hashtag is not a heading")])
    #expect(ChatMarkdown.blocks("") == [])
}

@Test func markdownReadsBulletedOrderedAndNestedLists() {
    let blocks = ChatMarkdown.blocks("Steps:\n- one\n  continued\n* two\n  - nested\n1. first\n2) second")
    #expect(blocks == [
        .paragraph("Steps:"),
        .item(marker: "•", indent: 0, text: "one\ncontinued"),
        .item(marker: "•", indent: 0, text: "two"),
        .item(marker: "•", indent: 1, text: "nested"),
        .item(marker: "1.", indent: 0, text: "first"),
        .item(marker: "2.", indent: 0, text: "second"),
    ])
    #expect(ChatMarkdown.blocks("**bold** start, not a list") == [.paragraph("**bold** start, not a list")])
}

@Test func markdownKeepsCodeBlocksVerbatim() {
    let blocks = ChatMarkdown.blocks("Run:\n```swift\nlet a = 1\n\n# not a heading\n- not a list\n```\nDone")
    #expect(blocks == [
        .paragraph("Run:"),
        .code(language: "swift", text: "let a = 1\n\n# not a heading\n- not a list"),
        .paragraph("Done"),
    ])
    // While a reply is still streaming the closing fence has not arrived yet.
    #expect(ChatMarkdown.blocks("```\nhalf") == [.code(language: "", text: "half")])
}

@Test func markdownMergesQuoteLines() {
    #expect(ChatMarkdown.blocks("> one\n>two\nafter") == [.quote("one\ntwo"), .paragraph("after")])
}
