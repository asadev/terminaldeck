import Foundation

/// A test-only JSON tree. It makes atomic Caddy updates inspectable without
/// sharing mutable Foundation dictionaries between connection handlers.
enum DKTCaddyJSON: Codable, Equatable, Sendable {
    case object([String: DKTCaddyJSON])
    case array([DKTCaddyJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode([DKTCaddyJSON].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: DKTCaddyJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(object): try value.encode(object)
        case let .array(array): try value.encode(array)
        case let .string(string): try value.encode(string)
        case let .number(number): try value.encode(number)
        case let .bool(bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    init(data: Data) throws { self = try JSONDecoder().decode(Self.self, from: data) }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func value(at path: [String]) throws -> Self {
        guard let component = path.first else { return self }
        let remainder = Array(path.dropFirst())
        switch self {
        case let .object(object):
            // Caddy exports null for a missing final object key.
            guard let value = object[component] else {
                if remainder.isEmpty { return .null }
                throw DKTCaddyConfigError(400, "config path is not traversable")
            }
            return try value.value(at: remainder)
        case let .array(array):
            let index = try Self.arrayIndex(component, upperBound: array.count)
            return try array[index].value(at: remainder)
        default: throw DKTCaddyConfigError(400, "config path is not traversable")
        }
    }

    func changing(method: String, path: [String], payload: Self) throws -> Self {
        guard let component = path.first else {
            switch method {
            case "POST":
                if case let .array(existing) = self { return .array(existing + [payload]) }
                return payload
            case "PATCH": return payload
            case "DELETE": return .null
            case "PUT": throw DKTCaddyConfigError(409, "config key already exists")
            default: throw DKTCaddyConfigError(405, "method is not allowed")
            }
        }
        let remainder = Array(path.dropFirst())
        switch self {
        case var .object(object):
            if remainder.isEmpty {
                switch method {
                case "POST":
                    object[component] = try (object[component] ?? .null)
                        .changing(method: method, path: [], payload: payload)
                case "PUT":
                    guard object[component] == nil else {
                        throw DKTCaddyConfigError(409, "config key already exists")
                    }
                    object[component] = payload
                case "PATCH", "DELETE":
                    guard object[component] != nil else {
                        throw DKTCaddyConfigError(404, "config key does not exist")
                    }
                    if method == "DELETE" { object.removeValue(forKey: component) }
                    else { object[component] = payload }
                default: throw DKTCaddyConfigError(405, "method is not allowed")
                }
            } else {
                // Caddy PUT creates absent intermediate objects; other verbs do not.
                let child = object[component] ?? (method == "PUT" ? .object([:]) : .null)
                object[component] = try child.changing(method: method, path: remainder, payload: payload)
            }
            return .object(object)
        case var .array(array):
            if component == "..." {
                guard method == "POST", remainder.isEmpty, case let .array(additions) = payload else {
                    throw DKTCaddyConfigError(400, "array expansion requires POST and an array payload")
                }
                return .array(array + additions)
            }
            let insert = method == "PUT" && remainder.isEmpty
            let index = try Self.arrayIndex(component, upperBound: array.count, allowsEnd: insert)
            if remainder.isEmpty {
                switch method {
                case "PUT": array.insert(payload, at: index)
                case "DELETE": array.remove(at: index)
                case "PATCH": array[index] = payload
                case "POST":
                    // POST into an array appends, including an index path.
                    array.append(payload)
                default: throw DKTCaddyConfigError(405, "method is not allowed")
                }
            } else {
                array[index] = try array[index].changing(method: method, path: remainder, payload: payload)
            }
            return .array(array)
        default: throw DKTCaddyConfigError(400, "config path is not traversable")
        }
    }

    func path(forID id: String, prefix: [String] = []) -> [String]? {
        switch self {
        case let .object(object):
            if object["@id"] == .string(id) { return prefix }
            for key in object.keys.sorted() {
                if let result = object[key]?.path(forID: id, prefix: prefix + [key]) { return result }
            }
        case let .array(array):
            for (index, value) in array.enumerated() {
                if let result = value.path(forID: id, prefix: prefix + [String(index)]) { return result }
            }
        default: break
        }
        return nil
    }

    /// Validates the HTTP config structures used by Apps. This deliberately does
    /// not claim to provision Caddy modules, request certificates, or check DNS.
    func validateConfig() throws {
        guard case let .object(root) = self else {
            if self == .null { return } // DELETE /config/ unloads the current config.
            throw DKTCaddyConfigError(400, "Caddy config must be a JSON object")
        }
        var ids = Set<String>()
        try validateIDs(into: &ids)
        guard let appsValue = root["apps"] else { return }
        guard case let .object(apps) = appsValue else {
            throw DKTCaddyConfigError(400, "apps must be an object")
        }
        guard let httpValue = apps["http"] else { return }
        guard case let .object(http) = httpValue else {
            throw DKTCaddyConfigError(400, "HTTP app must be an object")
        }
        guard let serversValue = http["servers"] else { return }
        guard case let .object(servers) = serversValue else {
            throw DKTCaddyConfigError(400, "HTTP servers must be an object")
        }
        for server in servers.values {
            guard case let .object(fields) = server else {
                throw DKTCaddyConfigError(400, "HTTP server must be an object")
            }
            if let listen = fields["listen"] { try Self.validateStrings(listen, field: "listen") }
            if let routes = fields["routes"] { try Self.validateRoutes(routes) }
        }
    }

    private func validateIDs(into ids: inout Set<String>) throws {
        switch self {
        case let .object(object):
            if let value = object["@id"] {
                guard case let .string(id) = value, !id.isEmpty, ids.insert(id).inserted else {
                    throw DKTCaddyConfigError(400, "config IDs must be unique nonempty strings")
                }
            }
            for child in object.values { try child.validateIDs(into: &ids) }
        case let .array(array):
            for child in array { try child.validateIDs(into: &ids) }
        default: break
        }
    }

    private static func validateStrings(_ value: Self, field: String) throws {
        guard case let .array(values) = value,
              values.allSatisfy({ if case let .string(text) = $0 { return !text.isEmpty }; return false }) else {
            throw DKTCaddyConfigError(400, "\(field) must be an array of nonempty strings")
        }
    }

    private static func validateRoutes(_ value: Self) throws {
        guard case let .array(routes) = value else {
            throw DKTCaddyConfigError(400, "routes must be an array")
        }
        for route in routes {
            guard case let .object(fields) = route else {
                throw DKTCaddyConfigError(400, "route must be an object")
            }
            if let match = fields["match"] {
                guard case let .array(matches) = match else {
                    throw DKTCaddyConfigError(400, "match must be an array")
                }
                for matcher in matches {
                    guard case let .object(properties) = matcher else {
                        throw DKTCaddyConfigError(400, "matcher must be an object")
                    }
                    if let host = properties["host"] { try validateStrings(host, field: "host") }
                }
            }
            if let handle = fields["handle"] {
                guard case let .array(handlers) = handle else {
                    throw DKTCaddyConfigError(400, "handle must be an array")
                }
                for handler in handlers {
                    guard case let .object(properties) = handler,
                          case let .string(name)? = properties["handler"], !name.isEmpty else {
                        throw DKTCaddyConfigError(400, "handler name is required")
                    }
                    if name == "reverse_proxy", let upstreams = properties["upstreams"] {
                        guard case let .array(values) = upstreams else {
                            throw DKTCaddyConfigError(400, "upstreams must be an array")
                        }
                        for upstream in values {
                            guard case let .object(properties) = upstream,
                                  case let .string(dial)? = properties["dial"], !dial.isEmpty else {
                                throw DKTCaddyConfigError(400, "upstream dial address is required")
                            }
                        }
                    }
                    if let routes = properties["routes"] { try validateRoutes(routes) }
                }
            }
        }
    }

    private static func arrayIndex(_ text: String, upperBound: Int, allowsEnd: Bool = false) throws -> Int {
        guard let index = Int(text), String(index) == text, index >= 0,
              index < upperBound || (allowsEnd && index == upperBound) else {
            throw DKTCaddyConfigError(400, "invalid or out-of-bounds array index")
        }
        return index
    }
}

struct DKTCaddyConfigError: Error, Sendable {
    let statusCode: Int
    let message: String
    init(_ statusCode: Int, _ message: String) {
        self.statusCode = statusCode
        self.message = message
    }
}
