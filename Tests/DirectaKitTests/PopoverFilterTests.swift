import Foundation
import Testing

@testable import DirectaKit

@Suite struct PopoverFilterTests {
    /** Each range as [offset, length] in Characters of the original text, so a
        test reads positions the way a reader counts them. */
    private func spans(_ text: String, _ ranges: [Range<String.Index>]?) -> [[Int]]? {
        ranges?.map { range in
            [
                text.distance(from: text.startIndex, to: range.lowerBound),
                text.distance(from: range.lowerBound, to: range.upperBound),
            ]
        }
    }

    @Test func emptyOrWhitespaceQueryMatchesWithNoRanges() {
        #expect(spans("myproj", FuzzyMatch.ranges(in: "myproj", query: "")) == [])
        #expect(spans("myproj", FuzzyMatch.ranges(in: "myproj", query: "   ")) == [])
    }

    @Test func caseInsensitiveSubstringReturnsOneRange() {
        #expect(spans("Myproj-DEV", FuzzyMatch.ranges(in: "Myproj-DEV", query: "dev")) == [[7, 3]])
        #expect(spans("my dev", FuzzyMatch.ranges(in: "my dev", query: "  dev  ")) == [[3, 3]])
    }

    @Test func subsequenceReturnsOneRangePerMatchedCharacter() {
        let text = "myproj-web"
        #expect(spans(text, FuzzyMatch.ranges(in: text, query: "mpw")) == [[0, 1], [2, 1], [7, 1]])
        #expect(spans(text, FuzzyMatch.ranges(in: text, query: "MPW")) == [[0, 1], [2, 1], [7, 1]])
    }

    @Test func noMatchReturnsNil() {
        #expect(FuzzyMatch.ranges(in: "myproj", query: "xyz") == nil)
        #expect(FuzzyMatch.ranges(in: "myproj", query: "jm") == nil)
    }

    @Test func rangesStayAlignedWhenLowercasingChangesLength() {
        /** "İ" (U+0130) lowercases to two scalars, so an index taken from a
            lowercased copy would land one Character late in the original. */
        let substring = "İ dev"
        #expect(spans(substring, FuzzyMatch.ranges(in: substring, query: "dev")) == [[2, 3]])
        let subsequence = "İdox"
        #expect(spans(subsequence, FuzzyMatch.ranges(in: subsequence, query: "dx")) == [[1, 1], [3, 1]])
    }

    @Test func addressShowsHostAndPortFromUrl() {
        #expect(
            PopoverLabel.address(
                url: "http://myproj.localhost:3000/", displayPort: 3000, server: "dev")
                == "myproj.localhost:3000")
    }

    @Test func addressShowsHostWithoutPortWhenUrlHasNoPort() {
        #expect(
            PopoverLabel.address(url: "https://example.com/app", displayPort: nil, server: "web")
                == "example.com")
    }

    @Test func addressFallsBackToPortWhenThereIsNoUrl() {
        #expect(PopoverLabel.address(url: nil, displayPort: 4100, server: "api") == "port 4100")
    }

    @Test func addressFallsBackToServerNameWhenThereIsNeitherUrlNorPort() {
        #expect(PopoverLabel.address(url: nil, displayPort: nil, server: "web") == "web")
    }

    @Test func headHostOmitsHostWhenSameAsParentAndKeepsPath() {
        #expect(
            PopoverLabel.headHost(
                url: "http://myproj.localhost:3000/qa", parentURL: "http://myproj.localhost:3000/")
                == "/qa")
    }

    @Test func headHostIsEmptyWhenSameAsParentWithoutPath() {
        #expect(
            PopoverLabel.headHost(
                url: "http://myproj.localhost:3000/", parentURL: "http://myproj.localhost:3000/")
                == "")
    }

    @Test func headHostShowsHostWhenDifferentFromParent() {
        #expect(
            PopoverLabel.headHost(
                url: "http://demo.localhost:3000/qa", parentURL: "http://myproj.localhost:3000/")
                == "demo.localhost:3000/qa")
    }

    @Test func headHostReturnsUnparseableUrlAsIs() {
        #expect(PopoverLabel.headHost(url: "http://[bad", parentURL: nil) == "http://[bad")
    }
}
