import Foundation
import TerminalDeckNativeCore

/// SRV2: bcrypt ($2b$) for app password protection. Caddy and Traefik both
/// verify bcrypt, so the Mac hashes once and only the hash reaches the server.
/// Blowfish's starting tables are the hex digits of pi; they are computed once
/// (Machin's formula on a small fixed-point integer) instead of pasted in.
public enum BackendAppsSRV2Bcrypt {
    public static let defaultCost = 10

    public static func hash(_ password: String, cost: Int = defaultCost) throws -> String {
        var generator = SystemRandomNumberGenerator()
        let salt = (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return try hash(password, cost: cost, salt: salt)
    }

    public static func hash(_ password: String, cost: Int, salt: [UInt8]) throws -> String {
        guard (4...31).contains(cost), salt.count == 16 else { throw NativeRPCError.invalidArguments("The password could not be protected.") }
        var key = Array(password.utf8.prefix(72))
        key.append(0)
        var state = State(tables.p, tables.s)
        state.expand(data: salt, key: key)
        for _ in 0..<(1 << cost) {
            state.expand0(key)
            state.expand0(salt)
        }
        let magic = Array("OrpheanBeholderScryDoubt".utf8)
        var words: [UInt32] = []
        for i in 0..<6 {
            var word: UInt32 = 0
            for byte in magic[(4 * i)..<(4 * i + 4)] { word = word << 8 | UInt32(byte) }
            words.append(word)
        }
        for _ in 0..<64 {
            for block in 0..<3 {
                let (l, r) = state.encipher(words[2 * block], words[2 * block + 1])
                words[2 * block] = l; words[2 * block + 1] = r
            }
        }
        var output: [UInt8] = []
        for word in words { output += [UInt8(word >> 24), UInt8((word >> 16) & 0xff), UInt8((word >> 8) & 0xff), UInt8(word & 0xff)] }
        return "$2b$" + (cost < 10 ? "0" : "") + String(cost) + "$" + encode(salt) + encode(Array(output.prefix(23)))
    }

    /// Verifies a password against an existing $2a$/$2b$/$2y$ hash (tests and checks).
    public static func verify(_ password: String, hash: String) -> Bool {
        guard NativeAppsOptions.isBcrypt(hash) else { return false }
        let characters = Array(hash)
        guard let cost = Int(String(characters[4...5])), let salt = decode(String(characters[7..<29]), count: 16),
              let computed = try? self.hash(password, cost: cost, salt: salt) else { return false }
        return computed.dropFirst(4) == hash.dropFirst(4)
    }

    // MARK: Blowfish

    struct State {
        var p: [UInt32]
        var s: [UInt32]
        init(_ p: [UInt32], _ s: [UInt32]) { self.p = p; self.s = s }

        @inline(__always) func f(_ x: UInt32) -> UInt32 {
            ((s[Int(x >> 24)] &+ s[256 + Int((x >> 16) & 0xff)]) ^ s[512 + Int((x >> 8) & 0xff)]) &+ s[768 + Int(x & 0xff)]
        }
        func encipher(_ left: UInt32, _ right: UInt32) -> (UInt32, UInt32) {
            var l = left ^ p[0], r = right
            var i = 1
            while i <= 16 {
                r ^= f(l) ^ p[i]
                l ^= f(r) ^ p[i + 1]
                i += 2
            }
            return (r ^ p[17], l)
        }
        static func word(_ data: [UInt8], _ index: inout Int) -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                value = value << 8 | UInt32(data[index])
                index = (index + 1) % data.count
            }
            return value
        }
        mutating func expand(data: [UInt8], key: [UInt8]) {
            var j = 0
            for i in 0..<18 { p[i] ^= Self.word(key, &j) }
            var l: UInt32 = 0, r: UInt32 = 0
            j = 0
            var i = 0
            while i < 18 {
                l ^= Self.word(data, &j); r ^= Self.word(data, &j)
                (l, r) = encipher(l, r); p[i] = l; p[i + 1] = r
                i += 2
            }
            i = 0
            while i < 1024 {
                l ^= Self.word(data, &j); r ^= Self.word(data, &j)
                (l, r) = encipher(l, r); s[i] = l; s[i + 1] = r
                i += 2
            }
        }
        mutating func expand0(_ key: [UInt8]) {
            var j = 0
            for i in 0..<18 { p[i] ^= Self.word(key, &j) }
            var l: UInt32 = 0, r: UInt32 = 0
            var i = 0
            while i < 18 { (l, r) = encipher(l, r); p[i] = l; p[i + 1] = r; i += 2 }
            i = 0
            while i < 1024 { (l, r) = encipher(l, r); s[i] = l; s[i + 1] = r; i += 2 }
        }
    }

    /// 18 P words then 4 x 256 S words: the first 8336 hex digits of pi after "3.".
    static let tables: (p: [UInt32], s: [UInt32]) = {
        let words = piFractionWords(1042)
        return (Array(words[0..<18]), Array(words[18..<1042]))
    }()

    /// pi = 16 atan(1/5) - 4 atan(1/239), on fixed-point integers with 64 guard bits.
    static func piFractionWords(_ count: Int) -> [UInt32] {
        let bits = count * 32 + 64
        let limbs = bits / 32 + 2
        func atanInverse(_ x: UInt32) -> [UInt32] {
            var sum = [UInt32](repeating: 0, count: limbs)
            var term = [UInt32](repeating: 0, count: limbs)
            term[bits / 32] = 1 << UInt32(bits % 32)
            _ = divide(&term, x)
            var quotient = term
            var k: UInt32 = 0
            let square = x * x
            while !isZero(term) {
                quotient = term
                _ = divide(&quotient, 2 * k + 1)
                if k % 2 == 0 { add(&sum, quotient) } else { subtract(&sum, quotient) }
                _ = divide(&term, square)
                k += 1
            }
            return sum
        }
        var pi = atanInverse(5)
        multiply(&pi, 16)
        var second = atanInverse(239)
        multiply(&second, 4)
        subtract(&pi, second)
        // Drop the integer part (3) and read 32-bit words from the top of the fraction.
        var words: [UInt32] = []
        for index in 0..<count {
            let high = bits - 32 * (index + 1)
            words.append(extract(pi, from: high))
        }
        return words
    }
    private static func extract(_ value: [UInt32], from bit: Int) -> UInt32 {
        let limb = bit / 32, offset = bit % 32
        if offset == 0 { return value[limb] }
        return (value[limb] >> UInt32(offset)) | (value[limb + 1] << UInt32(32 - offset))
    }
    private static func isZero(_ value: [UInt32]) -> Bool { !value.contains { $0 != 0 } }
    private static func divide(_ value: inout [UInt32], _ divisor: UInt32) -> UInt32 {
        var remainder: UInt64 = 0
        value.withUnsafeMutableBufferPointer { buffer in
            var index = buffer.count - 1
            while index >= 0 {
                let current = remainder << 32 | UInt64(buffer[index])
                buffer[index] = UInt32(current / UInt64(divisor))
                remainder = current % UInt64(divisor)
                index -= 1
            }
        }
        return UInt32(remainder)
    }
    private static func add(_ value: inout [UInt32], _ other: [UInt32]) {
        var carry: UInt64 = 0
        value.withUnsafeMutableBufferPointer { buffer in
            for index in 0..<buffer.count {
                let sum = UInt64(buffer[index]) + UInt64(other[index]) + carry
                buffer[index] = UInt32(truncatingIfNeeded: sum); carry = sum >> 32
            }
        }
    }
    private static func subtract(_ value: inout [UInt32], _ other: [UInt32]) {
        var borrow: Int64 = 0
        value.withUnsafeMutableBufferPointer { buffer in
            for index in 0..<buffer.count {
                var difference = Int64(buffer[index]) - Int64(other[index]) - borrow
                if difference < 0 { difference += 1 << 32; borrow = 1 } else { borrow = 0 }
                buffer[index] = UInt32(difference)
            }
        }
    }
    private static func multiply(_ value: inout [UInt32], _ factor: UInt32) {
        var carry: UInt64 = 0
        for index in 0..<value.count {
            let product = UInt64(value[index]) * UInt64(factor) + carry
            value[index] = UInt32(truncatingIfNeeded: product); carry = product >> 32
        }
    }

    // MARK: bcrypt's own base64

    private static let alphabet = Array("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    static func encode(_ bytes: [UInt8]) -> String {
        var out = "", index = 0
        while index < bytes.count {
            var c1 = Int(bytes[index]); index += 1
            out.append(alphabet[c1 >> 2])
            c1 = (c1 & 0x03) << 4
            if index >= bytes.count { out.append(alphabet[c1]); break }
            var c2 = Int(bytes[index]); index += 1
            c1 |= (c2 >> 4) & 0x0f
            out.append(alphabet[c1])
            c1 = (c2 & 0x0f) << 2
            if index >= bytes.count { out.append(alphabet[c1]); break }
            c2 = Int(bytes[index]); index += 1
            c1 |= (c2 >> 6) & 0x03
            out.append(alphabet[c1]); out.append(alphabet[c2 & 0x3f])
        }
        return out
    }
    static func decode(_ text: String, count: Int) -> [UInt8]? {
        var lookup = [Character: Int]()
        for (offset, character) in alphabet.enumerated() { lookup[character] = offset }
        let values = text.compactMap { lookup[$0] }
        guard values.count == text.count else { return nil }
        var out: [UInt8] = [], index = 0
        while out.count < count, index + 1 < values.count {
            let c1 = values[index], c2 = values[index + 1]
            out.append(UInt8((c1 << 2 | (c2 & 0x30) >> 4) & 0xff))
            if out.count >= count || index + 2 >= values.count { break }
            let c3 = values[index + 2]
            out.append(UInt8(((c2 & 0x0f) << 4 | (c3 & 0x3c) >> 2) & 0xff))
            if out.count >= count || index + 3 >= values.count { break }
            let c4 = values[index + 3]
            out.append(UInt8(((c3 & 0x03) << 6 | c4) & 0xff))
            index += 4
        }
        return out.count == count ? out : nil
    }
}
