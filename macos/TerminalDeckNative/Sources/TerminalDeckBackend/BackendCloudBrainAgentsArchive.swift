import Foundation
import TerminalDeckNativeCore

/// The owner-side ledger helper lives in Core (`CloudBrainAgentsArchive`) so Core owners such as the native
/// state store use the same import and capture protocol as the Backend owners.
public typealias BackendCloudBrainAgentsArchive = CloudBrainAgentsArchive
public typealias BackendCloudBrainAgentsSupport = CloudBrainAgentsSupport
