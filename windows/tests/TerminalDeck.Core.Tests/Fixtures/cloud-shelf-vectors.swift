// Reference cases for the Windows shelf port: the Mac's own formulas (BackendCloudShelf.swift, BackendCloudShelfSealed.swift,
// CloudSecretsShelfSeal.swift on lane/mac-next2), run with Apple's Foundation JSONEncoder and CryptoKit.
import Foundation
import CryptoKit

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func hash(_ d: Data) -> String { hex(Data(SHA256.hash(data: d))) }
func b64u(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
let sorted: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

struct Row: Codable {
    var key: String; var name: String; var changedAt: Int64; var place: String?; var changedBy: String?; var sizeBytes: Int64?
    var status: String?; var binary: Bool?; var textHash: String?; var textBytes: Int?; var textPieces: Int?
    var fileHash: String?; var fileBytes: Int64?; var fileType: String?
    var grouped = false
    enum CodingKeys: String, CodingKey { case key, name, changedAt, place, changedBy, sizeBytes, status, binary, textHash, textBytes, textPieces, fileHash, fileBytes, fileType }
}
func fingerprint(_ rows: [Row]) -> (String, String) {
    let steady = rows.map { r -> Row in guard r.grouped else { return r }; var c = r; c.changedAt = 0; c.sizeBytes = nil; c.status = nil; return c }
    let data = try! sorted.encode(steady)
    return (hash(data), String(decoding: data, as: UTF8.self))
}
let pieceBytes = 262_144
func pieces(_ text: String) -> [String] {
    guard text.utf8.count > pieceBytes else { return [text] }
    var made: [String] = []; var current = String.UnicodeScalarView(); var size = 0
    for s in text.unicodeScalars { let w = String(s).utf8.count; if size + w > pieceBytes { made.append(String(current)); current = .init(); size = 0 }; current.append(s); size += w }
    if !current.isEmpty || made.isEmpty { made.append(String(current)) }
    return made
}

// Sealed
let label = "TD-SHELF-SEALED-1"
func derive(_ input: Data, salt: Data, info: String) -> Data {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: input), salt: salt, info: Data(info.utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
}
func uuidBytes(_ t: String) -> Data { var raw = UUID(uuidString: t)!.uuid; return withUnsafeBytes(of: &raw) { Data($0) } }
func step(_ size: Int) -> Int? { var s = 256; while s < size { s *= 2 }; return s <= 262_144 ? s : nil }
func pad(_ b: Data) -> Data { let total = step(b.count + 4)!; let c = UInt32(b.count); var m = Data([UInt8(c >> 24 & 0xff), UInt8(c >> 16 & 0xff), UInt8(c >> 8 & 0xff), UInt8(c & 0xff)]); m.append(b); m.append(Data(count: total - m.count)); return m }
let root = Data(repeating: 9, count: 32)
let sub = "11111111-1111-4111-8111-111111111111"
let epoch = 3
let shelfRoot = derive(root, salt: Data(), info: "\(label)\nroot\n\(sub)\n\(epoch)")
let refKey = SymmetricKey(data: derive(shelfRoot, salt: Data(), info: "\(label)\nref"))
func mac(_ t: String) -> [UInt8] { Array(HMAC<SHA256>.authenticationCode(for: Data(t.utf8), using: refKey)) }
func ref(_ kind: String, _ itemKey: String) -> String { mac("item\n\(kind)\n\(itemKey)").prefix(16).map { String(format: "%02x", $0) }.joined() }
func valueId(_ kind: String, _ itemKey: String, _ bytes: Data) -> String {
    var raw = Array(mac("value\n\(kind)\n\(itemKey)\n" + hash(bytes)).prefix(16))
    raw[6] = raw[6] & 0x0f | 0x40; raw[8] = raw[8] & 0x3f | 0x80
    return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15])).uuidString.lowercased()
}
func fp(_ bytes: Data) -> String { HMAC<SHA256>.authenticationCode(for: Data("fingerprint\n".utf8) + bytes, using: refKey).map { String(format: "%02x", $0) }.joined() }
func seal(_ bytes: Data, kind: String, role: String, pieceId: String, nonce: Data) -> [String: String] {
    let key = derive(shelfRoot, salt: uuidBytes(pieceId), info: "\(label)\n\(kind)\n\(role)\n\(epoch)")
    let aad = Data("\(label)\n\(sub)\n\(kind)\n\(role)\n\(epoch)\n\(pieceId)".utf8)
    let box = try! AES.GCM.seal(pad(bytes), using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
    return ["nonce": b64u(nonce), "ciphertext": b64u(box.ciphertext), "tag": b64u(box.tag)]
}
struct Field: Codable { let label: String; let value: String; let secret: Bool }
struct Value: Codable { let v: Int; let fields: [Field] }
struct SavedPassword: Codable {
    let ref: String; let name: String; let purpose: String; let place: String?; let changedAt: Int64?; let value: String; let valueBytes: Int; let labels: [String]
    enum CodingKeys: String, CodingKey { case ref, name, purpose = "for", place, changedAt, value, valueBytes, labels }
}
struct SecretFile: Codable { let ref: String; let project: String; let file: String; let place: String; let changedAt: Int64?; let changedBy: String?; let sizeBytes: Int; let value: String }
struct Steady: Encodable { let passwords: [SavedPassword]; let files: [SecretFile] }
struct Index: Codable {
    let v: Int; let kind: String; let putId: String; let part: Int; let parts: Int; let madeAt: Int64; let madeBy: String; let count: Int
    let passwords: [SavedPassword]?; let files: [SecretFile]?
}

var out: [String: Any] = ["format": "td-shelf-vectors-1", "source": "lane/mac-next2 BackendCloudShelf.swift, BackendCloudShelfSealed.swift, CloudSecretsShelfSeal.swift; Apple Foundation JSONEncoder(.sortedKeys) + CryptoKit"]

// 1. Rows fingerprints
var rowsA: [Row] = [
    Row(key: "memory|Terminal Deck · Decker|projects/td/roles/decker/notes/a.md", name: "Open items — \"today\"", changedAt: 1763200000123, place: "Terminal Deck · Decker", changedBy: "Mac mini", sizeBytes: 2048, status: nil, binary: nil, textHash: String(repeating: "a", count: 64), textBytes: 2048, textPieces: 1),
    Row(key: "cloudFolder||Pictures/cat 1.png", name: "cat 1.png", changedAt: 5, place: nil, changedBy: "This PC", sizeBytes: 3, status: nil, binary: true, textHash: nil, textBytes: nil, textPieces: nil, fileHash: String(repeating: "b", count: 64), fileBytes: 3, fileType: "image/png"),
    Row(key: "settings||setting:theme", name: "Tab\tand\u{1}\u{1f}control\u{7f} é 日本 😀 <b>&", changedAt: 0, place: "General › Look", status: "On"),
]
var grouped = Row(key: "memory|diary", name: "Diary", changedAt: 99, place: nil, changedBy: "MacBook Pro", sizeBytes: 77, status: "58 entries")
grouped.grouped = true
rowsA.append(grouped)
let (fA, jA) = fingerprint(rowsA)
var groupedLater = grouped; groupedLater.changedAt = 12345; groupedLater.sizeBytes = 999; groupedLater.status = "59 entries"
let (fB, _) = fingerprint(Array(rowsA.dropLast()) + [groupedLater])
let (fEmpty, jEmpty) = fingerprint([])
func rowJSON(_ r: Row) -> [String: Any] {
    var o: [String: Any] = ["key": r.key, "name": r.name, "changedAt": r.changedAt, "grouped": r.grouped]
    if let v = r.place { o["place"] = v }; if let v = r.changedBy { o["changedBy"] = v }; if let v = r.sizeBytes { o["sizeBytes"] = v }
    if let v = r.status { o["status"] = v }; if let v = r.binary { o["binary"] = v }; if let v = r.textHash { o["textHash"] = v }
    if let v = r.textBytes { o["textBytes"] = v }; if let v = r.textPieces { o["textPieces"] = v }; if let v = r.fileHash { o["fileHash"] = v }
    if let v = r.fileBytes { o["fileBytes"] = v }; if let v = r.fileType { o["fileType"] = v }
    return o
}
out["rows"] = rowsA.map(rowJSON)
out["rowsFingerprint"] = fA
out["rowsJson"] = jA
out["rowsFingerprintGroupedMoved"] = fB
out["emptyFingerprint"] = fEmpty
out["emptyJson"] = jEmpty

// 2. Text facts
let textSmall = "Hello / world\n\"quoted\" é 😀"
var big = String(repeating: "abcdefgh", count: 32_768)  // 262,144 bytes exactly
big += "é😀tail"
var facts: [[String: Any]] = []
for (name, t) in [("small", textSmall), ("empty", ""), ("overOnePiece", big)] {
    let d = Data(t.utf8); let p = pieces(t)
    facts.append(["name": name, "hash": hash(d), "bytes": d.count, "pieces": p.count, "pieceBytes": p.map { $0.utf8.count }])
}
out["textFacts"] = facts
out["bigText"] = ["repeat": "abcdefgh", "times": 32768, "tail": "é😀tail"]

// 3. Sealed
let itemKey = "servers\nsrv-1"
let value = try! sorted.encode(Value(v: 1, fields: [Field(label: "User", value: "root/admin", secret: false), Field(label: "Password", value: "p\"w é", secret: true)]))
let vid = valueId("savedPasswords", itemKey, value)
let pieceId = "22222222-2222-4222-8222-222222222222"
let nonce = Data((0..<12).map { UInt8($0) })
let sealedValue = seal(value, kind: "savedPasswords", role: "value", pieceId: vid, nonce: nonce)
let pw = SavedPassword(ref: ref("savedPasswords", itemKey), name: "Web server", purpose: "Server", place: "10.0.0.5:2222", changedAt: nil, value: vid, valueBytes: value.count, labels: ["User", "Password"])
let steady = try! sorted.encode(Steady(passwords: [pw], files: []))
let index = try! sorted.encode(Index(v: 1, kind: "savedPasswords", putId: "33333333-3333-4333-8333-333333333333", part: 0, parts: 1, madeAt: 1763200000000, madeBy: "Office PC", count: 1, passwords: [pw], files: nil))
let sealedIndex = seal(index, kind: "savedPasswords", role: "index", pieceId: pieceId, nonce: nonce)
let fileBytes = Data("API_KEY=abc\n".utf8)
let fileKey = "project-secret-files\nproj-1/.env"
let sf = SecretFile(ref: ref("projectSecretFiles", fileKey), project: "Garden", file: ".env", place: "app/.env", changedAt: 1763200000001, changedBy: "Mac mini", sizeBytes: fileBytes.count, value: valueId("projectSecretFiles", fileKey, fileBytes))
let steadyFiles = try! sorted.encode(Steady(passwords: [], files: [sf]))
out["sealed"] = [
    "testOnlyRootHex": hex(root), "sub": sub, "epoch": epoch,
    "shelfRootHex": hex(shelfRoot),
    "itemKey": itemKey, "ref": pw.ref, "valueJson": String(decoding: value, as: UTF8.self), "valueId": vid,
    "nonceHex": hex(nonce), "valuePiece": sealedValue, "paddedValueHex": hex(pad(value)),
    "steadyJson": String(decoding: steady, as: UTF8.self), "fingerprint": fp(steady),
    "indexPieceId": pieceId, "indexJson": String(decoding: index, as: UTF8.self), "indexPiece": sealedIndex,
    "fileItemKey": fileKey, "fileBytesHex": hex(fileBytes), "fileRef": sf.ref, "fileValueId": sf.value,
    "steadyFilesJson": String(decoding: steadyFiles, as: UTF8.self), "filesFingerprint": fp(steadyFiles),
    "steps": [[1, 256], [252, 256], [253, 512], [262_140, 262_144], [262_141, -1]].map { [$0[0], step($0[0] + 0) ?? -1] }
] as [String: Any]

let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: data)
print("ok")
