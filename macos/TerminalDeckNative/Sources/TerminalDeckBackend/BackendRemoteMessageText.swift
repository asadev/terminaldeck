import Foundation
import TerminalDeckNativeCore

extension BackendRemoteProtocol {
    /// Newlines and tabs are normal composer input; terminal control bytes are not.
    static func messageText(_ reader: BackendRemoteReader, allowEmpty: Bool) throws -> String {
        let value = try reader.text("text", reason: "Write a message or attach a file.", allowEmpty: allowEmpty,
                                    bytes: 16_384, oversize: "Messages can contain at most 16,384 bytes.")
        guard !value.unicodeScalars.contains(where: { scalar in
            let code = scalar.value
            return code < 32 && ![9, 10, 13].contains(code) || (127...159).contains(code)
        }) else { throw reader.bad("The message contains an unsupported control character.") }
        return value
    }
}
