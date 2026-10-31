import Foundation

extension TaskFields {
    // MARK: Labels

    public static func normaliseLabel(_ raw: String?) -> FieldRes<String> {
        guard let raw else { return .failure(FieldFail("Field name is required")) }
        let s = collapse(raw)
        if s.isEmpty { return .failure(FieldFail("Field name is required")) }
        if s.utf16.count > maxFieldLabel { return .failure(FieldFail("Field name is too long (\(maxFieldLabel) characters max)")) }
        if s.contains("{") || s.contains("}") { return .failure(FieldFail("Field names cannot contain { or }")) }
        return .success(s)
    }

    /// Case-insensitive: "Price" and "price" are the same name on one task.
    public static func sameLabel(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).lowercased() == b.trimmingCharacters(in: .whitespaces).lowercased()
    }

}
