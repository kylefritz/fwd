import Testing
@testable import FwdCore

@Suite struct PortPatternTests {
    @Test func singlePort() throws {
        let p = try PortPattern.parse("3000")
        #expect(p.remoteRange == 3000...3000)
        #expect(p.offset == 0)
        #expect(!p.isWildcard)
        #expect(p.text == "3000")
        #expect(p.laptopPort(for: 3000) == 3000)
    }

    @Test(arguments: ["3000 -> 4000", "3000->4000", "3000 → 4000", "  3000  ->  4000 "])
    func arrowForms(_ input: String) throws {
        let p = try PortPattern.parse(input)
        #expect(p.remoteRange == 3000...3000)
        #expect(p.laptopPort(for: 3000) == 4000)
        #expect(p.text == "3000 -> 4000")
    }

    @Test func wildcard() throws {
        let p = try PortPattern.parse("31**")
        #expect(p.remoteRange == 3100...3199)
        #expect(p.isWildcard)
        #expect(p.laptopPort(for: 3142) == 3142)
        #expect(p.laptopPort(for: 3200) == nil)
    }

    @Test func wildcardWithOffset() throws {
        let p = try PortPattern.parse("3*** -> 4***")
        #expect(p.remoteRange == 3000...3999)
        #expect(p.laptopPort(for: 3456) == 4456)
        #expect(p.text == "3*** -> 4***")
    }

    @Test func wildcardAcrossDifferentWidths() throws {
        let p = try PortPattern.parse("3*** -> 14***")
        #expect(p.laptopPort(for: 3001) == 14001)
    }

    @Test func lowRemotePortIsFineWhenMapped() throws {
        let p = try PortPattern.parse("80 -> 8080")
        #expect(p.remoteRange == 80...80)
        #expect(p.laptopPort(for: 80) == 8080)
    }

    @Test func sameOnBothSidesCollapses() throws {
        #expect(try PortPattern.parse("3000 -> 3000").text == "3000")
        #expect(try PortPattern.parse("03000").text == "3000")
    }

    @Test func topOfRangeIsClamped() throws {
        let p = try PortPattern.parse("6****")
        #expect(p.remoteRange == 60000...65535)
    }

    @Test func wildcardSkipsLaptopPortsBelow1024() throws {
        let p = try PortPattern.parse("1***")
        #expect(p.laptopPort(for: 1000) == nil)
        #expect(p.laptopPort(for: 1024) == 1024)
    }

    @Test func rejections() {
        #expect(throws: PortPattern.ParseError.empty) { try PortPattern.parse("") }
        #expect(throws: PortPattern.ParseError.empty) { try PortPattern.parse("3000 ->") }
        #expect(throws: PortPattern.ParseError.notAPort("abc")) { try PortPattern.parse("abc") }
        #expect(throws: PortPattern.ParseError.notAPort("30-40")) { try PortPattern.parse("30-40") }
        #expect(throws: PortPattern.ParseError.outOfRange("70000")) { try PortPattern.parse("70000") }
        #expect(throws: PortPattern.ParseError.outOfRange("0")) { try PortPattern.parse("0") }
        #expect(throws: PortPattern.ParseError.outOfRange("300000")) { try PortPattern.parse("300000") }
        #expect(throws: PortPattern.ParseError.wildcardNotAtEnd("3*00")) { try PortPattern.parse("3*00") }
        #expect(throws: PortPattern.ParseError.wildcardNotAtEnd("***")) { try PortPattern.parse("***") }
        #expect(throws: PortPattern.ParseError.wildcardMismatch) { try PortPattern.parse("3*** -> 4**") }
        #expect(throws: PortPattern.ParseError.wildcardMismatch) { try PortPattern.parse("3000 -> 4***") }
        #expect(throws: PortPattern.ParseError.laptopPortTooLow(80)) { try PortPattern.parse("80") }
        #expect(throws: PortPattern.ParseError.laptopPortTooLow(443)) { try PortPattern.parse("3000 -> 443") }
        #expect(throws: PortPattern.ParseError.laptopPortTooLow(899)) { try PortPattern.parse("8**") }
        #expect(throws: PortPattern.ParseError.tooManyArrows) { try PortPattern.parse("1 -> 2 -> 3") }
    }
}
