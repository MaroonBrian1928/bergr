import Testing
@testable import bergr

struct LinkedSetupTests {
    @Test func readsUserAddressAndKey() {
        #expect(LinkedSetup.parse("brian\n192.168.1.50\nkey-ok\n") == .init(user: "brian", address: "192.168.1.50", keyAdded: true))
    }

    @Test func missingPartsStayNil() {
        #expect(LinkedSetup.parse("brian\n\n") == .init(user: "brian", address: nil, keyAdded: false))
    }

    @Test func aliasGivesWayToTheFoundAddress() {
        #expect(LinkedSetup.address(target: "newcloud", found: "198.23.235.238") == "198.23.235.238")
        #expect(LinkedSetup.address(target: "192.168.1.50", found: "10.0.0.2") == "192.168.1.50")
        #expect(LinkedSetup.address(target: "pi.local", found: nil) == "pi.local")
        #expect(LinkedSetup.address(target: "thinkpad", found: nil) == "thinkpad")
    }
}
