import Foundation
import HerdrKit
import Testing
@testable import hirte

@MainActor
struct ThemeTests {
    @Test func bundledThemesLoad() {
        // More than the built-in fallback: themes.json is in the app and decodes.
        #expect(TerminalTheme.all.count > 1)
        #expect(!TerminalTheme.darkThemes.isEmpty)
        #expect(!TerminalTheme.lightThemes.isEmpty)
    }

    @Test func everyThemeHasSixteenColors() {
        for theme in TerminalTheme.all {
            #expect(theme.ansi.count == 16, "\(theme.id)")
        }
    }

    @Test func defaultsExistAndUnknownIdsFallBack() {
        #expect(TerminalTheme.find(TerminalTheme.defaultDark, dark: true).id == TerminalTheme.defaultDark)
        #expect(TerminalTheme.find(TerminalTheme.defaultLight, dark: false).id == TerminalTheme.defaultLight)
        #expect(TerminalTheme.find("no-such-theme", dark: true).id == TerminalTheme.defaultDark)
        // A dark theme's id asked for as light falls back to the light default.
        #expect(TerminalTheme.find(TerminalTheme.defaultDark, dark: false).id == TerminalTheme.defaultLight)
    }
}

@MainActor
struct HostTests {
    @Test func subtitleShowsPortOnlyWhenNotDefault() {
        var host = Host(name: "Mini", target: SSHTarget(host: "mini.local", username: "pavel"))
        #expect(host.subtitle == "pavel@mini.local")
        host.target.port = 2222
        #expect(host.subtitle == "pavel@mini.local:2222")
    }

    @Test func hostsSavedBeforeTheDemoExistedStillDecode() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Mini","target":{"host":"mini.local","port":22,"username":"pavel"}}]"#
        let hosts = try JSONDecoder().decode([Host].self, from: Data(json.utf8))
        #expect(hosts.first?.isDemo == false)
    }

    @Test func storePersistsAndAddsTheDemoOnce() throws {
        let suite = "hirteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = HostStore(defaults: defaults)
        store.save(Host(name: "Mini", target: SSHTarget(host: "mini.local", username: "pavel")))
        let demo = store.addDemo()
        #expect(store.addDemo().id == demo.id)

        let reloaded = HostStore(defaults: defaults)
        #expect(reloaded.hosts.map(\.name) == ["Mini", "Demo machine"])
        #expect(reloaded.hasDemo)
    }
}

struct AgeTests {
    @Test func shortAgesLikeHerdrApp() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func age(_ seconds: TimeInterval) -> String { Terminal.shortAge(now.addingTimeInterval(-seconds), now: now) }
        #expect(age(59) == "now")
        #expect(age(-30) == "now")  // the machine's clock is ahead
        #expect(age(60) == "1m")
        #expect(age(47 * 60 + 59) == "47m")
        #expect(age(3 * 3600) == "3h")
        #expect(age(23 * 3600 + 3599) == "23h")
        #expect(age(2 * 86_400) == "2d")
    }
}
