import Testing
import TerminalDeckNativeCore

/// Sync review round 5 item 1: the service accepts only `^[a-z0-9][a-z0-9/_-]*$` (≤128 bytes) as a pack domain.
@Suite("Cloud domain names follow the service's rule")
struct CloudDomainNameTests {
    @Test func everyDomainLaneARegistersIsAcceptedByTheService() throws {
        let names = CloudBrainMemoryFormat.inventoryRows.map(CloudBrainMemoryFormat.domain)
            + CloudBrainFilesFormat.inventoryRows.map(CloudBrainFilesFormat.domain) + ["machines/paths"]
        for name in names {
            #expect(CloudWire.isValidDomain(name))
            #expect(try CloudWire.domain(name) == name)
            #expect(name == name.lowercased())
        }
        #expect(CloudBrainMemoryFormat.domain("I01") == "brain/memory/i01")
        #expect(CloudBrainFilesFormat.domain("I08") == "brain/files/i08")
    }
    @Test func anInvalidDomainCannotBeConstructed() {
        for bad in ["brain/memory/I01", "", "/brain", "-x", "brain memory", "brain.memory", String(repeating: "a", count: 129)] {
            #expect(!CloudWire.isValidDomain(bad))
            #expect(throws: CloudFailure.invalidRequest) { _ = try CloudWire.domain(bad) }
        }
        #expect(CloudWire.isValidDomain(String(repeating: "a", count: 128)))
    }
}
