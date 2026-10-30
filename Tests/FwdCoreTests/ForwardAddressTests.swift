import Foundation
import Testing
@testable import FwdCore

private func pill(_ remote: Int?, name: String?, state: PillState = .live, on: Bool = true, local: Int? = nil,
                  wildcard: Bool = false) -> Pill {
    Pill(text: remote.map(String.init) ?? "31**", on: on, state: state, isWildcard: wildcard, local: local,
         label: "", moved: false, ports: [], remote: remote, name: name, keep: false)
}

private func card(_ name: String, state: HostState = .connected, _ pills: [Pill]) -> HostCard {
    HostCard(name: name, state: state, statusLine: "", pills: pills, configPills: [], lastError: nil, inConfig: true)
}

@Suite struct ForwardAddressTests {
    @Test func namesAreCleanedUpForAnAddress() {
        #expect(ForwardAddress.slug("web") == "web")
        #expect(ForwardAddress.slug("My API") == "my-api")
        #expect(ForwardAddress.slug("  a__b  ") == "a-b")
        #expect(ForwardAddress.slug("café") == "cafe")
        #expect(ForwardAddress.slug("dev.example.com") == "dev-example-com")
        #expect(ForwardAddress.slug("!!!") == nil)
        #expect(ForwardAddress.slug("") == nil)
    }

    @Test func aNamedSinglePortGetsAnAddress() {
        let book = AddressBook(cards: [card("devbox", [pill(8765, name: "web", local: 8765)])])
        #expect(book.addresses.map(\.address) == ["web.localhost"])
        #expect(book.addresses[0].status == .ready(local: 8765))
    }

    @Test func unnamedWildcardAndScreenSharingEntriesGetNone() {
        let book = AddressBook(cards: [card("devbox", [
            pill(3000, name: nil),
            pill(nil, name: "all", wildcard: true),
            pill(5900, name: "vnc"),
            pill(4000, name: "!!!"),
        ])])
        #expect(book.addresses.isEmpty)
    }

    @Test func aNameOnTwoHostsCarriesTheHostOnBoth() {
        let book = AddressBook(cards: [
            card("devbox", [pill(3000, name: "web", local: 3000)]),
            card("staging", [pill(3000, name: "web", local: 3001)]),
        ])
        #expect(book.addresses.map(\.address) == ["web.devbox.localhost", "web.staging.localhost"])
        #expect(book.route(hostHeader: "web.staging.localhost") == .forward(book.addresses[1], port: 3001))
        guard case .page(.several(let name, let found)) = book.route(hostHeader: "web.localhost") else {
            Issue.record("bare name should list both")
            return
        }
        #expect(name == "web")
        #expect(found.map(\.host) == ["devbox", "staging"])
    }

    @Test func anOffEntryStillCountsSoAddressesDoNotMoveWithToggles() {
        let book = AddressBook(cards: [
            card("devbox", [pill(3000, name: "web", local: 3000)]),
            card("staging", [pill(3000, name: "web", state: .off, on: false)]),
        ])
        #expect(book.addresses.map(\.address) == ["web.devbox.localhost", "web.staging.localhost"])
    }

    @Test func onTheSameHostTheLowestPortKeepsTheAddressWhateverIsOn() {
        let cards = [card("devbox", [
            pill(5000, name: "my-api", local: 5000),
            pill(4000, name: "my api", state: .off, on: false),
        ])]
        let book = AddressBook(cards: cards)
        let winner = book.addresses.first { !$0.duplicate }
        #expect(winner?.remote == 4000)
        #expect(book.addresses.filter(\.duplicate).map(\.remote) == [5000])
        guard case .page(.down(let found)) = book.route(hostHeader: "my-api.localhost") else {
            Issue.record("the address belongs to the off entry")
            return
        }
        #expect(found.remote == 4000)
    }

    @Test func statusFollowsThePillAndItsHost() {
        func status(_ pill: Pill, _ host: HostState) -> ForwardAddress.Status? {
            AddressBook(cards: [card("devbox", state: host, [pill])]).addresses.first?.status
        }
        #expect(status(pill(3000, name: "w", state: .off, on: false), .connected) == .off)
        #expect(status(pill(3000, name: "w", state: .pending), .standby) == .notConnected)
        #expect(status(pill(3000, name: "w", state: .pending), .idle) == .notConnected)
        #expect(status(pill(3000, name: "w", state: .pending), .paused("asleep")) == .notConnected)
        #expect(status(pill(3000, name: "w", state: .pending), .connecting) == .connecting)
        #expect(status(pill(3000, name: "w", state: .pending), .retrying) == .connecting)
        #expect(status(pill(3000, name: "w", state: .pending), .needsAttention("key")) == .needsPerson("key"))
        #expect(status(pill(3000, name: "w", state: .waiting, local: 3100), .connected) == .waiting(local: 3100))
        #expect(status(pill(3000, name: "w", state: .blocked("taken")), .connected) == .blocked("taken"))
        #expect(status(pill(3000, name: "w", state: .active, local: 3100), .connected) == .ready(local: 3100))
    }

    @Test func theRouteUsesTheBoundPortNotTheOneAskedFor() {
        let book = AddressBook(cards: [card("devbox", [pill(3000, name: "web", local: 3107)])])
        #expect(book.route(hostHeader: "web.localhost") == .forward(book.addresses[0], port: 3107))
    }

    @Test func hostHeadersAreReadTheWayBrowsersSendThem() {
        let book = AddressBook(cards: [card("devbox", [pill(3000, name: "web", local: 3000)])])
        let up = NameRoute.forward(book.addresses[0], port: 3000)
        #expect(book.route(hostHeader: "web.localhost:80") == up)
        #expect(book.route(hostHeader: "WEB.LocalHost") == up)
        #expect(book.route(hostHeader: "web.localhost.") == up)
    }

    @Test func anythingElseIsUnknown() {
        let book = AddressBook(cards: [card("devbox", [pill(3000, name: "web", local: 3000)])])
        for header in ["evil.example", "localhost", "127.0.0.1", "[::1]:80", "nope.localhost", "web.example.localhost"] {
            guard case .page(.unknown) = book.route(hostHeader: header) else {
                Issue.record("\(header) should be unknown")
                continue
            }
        }
    }

    @Test func aDownForwardGetsAPageNotAPort() {
        let book = AddressBook(cards: [card("devbox", state: .standby, [pill(3000, name: "web", state: .pending)])])
        #expect(book.route(hostHeader: "web.localhost") == .page(.down(book.addresses[0])))
    }
}

@Suite struct NamePageTests {
    private func address(_ status: ForwardAddress.Status) -> ForwardAddress {
        ForwardAddress(address: "web.localhost", name: "web", host: "devbox", text: "8765", remote: 8765, status: status)
    }

    @Test func offOffersTurnOn() {
        let html = NamePages.html(for: .down(address(.off)))
        #expect(html.contains("web is off"))
        #expect(html.contains("action=\"/__fwd/on\""))
        #expect(html.contains("method=\"post\""))
    }

    @Test func notConnectedOffersConnect() {
        let html = NamePages.html(for: .down(address(.notConnected)))
        #expect(html.contains("web isn&#39;t connected"))
        #expect(html.contains("action=\"/__fwd/connect\""))
    }

    @Test func aHostThatNeedsAPersonHasNoButton() {
        let html = NamePages.html(for: .down(address(.needsPerson("Host key changed"))))
        #expect(html.contains("Host key changed"))
        #expect(!html.contains("<form"))
    }

    @Test func aBlockedForwardHasNoButton() {
        #expect(!NamePages.html(for: .down(address(.blocked("Port taken")))).contains("<form"))
    }

    @Test func waitingLinksToThePort() {
        let html = NamePages.html(for: .down(address(.waiting(local: 8766))))
        #expect(html.contains("http://localhost:8766"))
        #expect(!html.contains("<form"))
    }

    @Test func severalLinksToEach() {
        let html = NamePages.html(for: .several("web", [
            ForwardAddress(address: "web.a.localhost", name: "web", host: "a", text: "1", remote: 1, status: .off),
            ForwardAddress(address: "web.b.localhost", name: "web", host: "b", text: "1", remote: 1, status: .off),
        ]))
        #expect(html.contains("href=\"http://web.a.localhost\""))
        #expect(html.contains("href=\"http://web.b.localhost\""))
    }

    @Test func whatTheBrowserSentIsEscaped() {
        let html = NamePages.html(for: .unknown("<script>alert(1)</script>.localhost"))
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
    }

    @Test func aNameIsEscapedToo() {
        let html = NamePages.html(for: .down(ForwardAddress(address: "x.localhost", name: "<b>", host: "h", text: "1",
                                                            remote: 1, status: .off)))
        #expect(!html.contains("<b>"))
    }
}
