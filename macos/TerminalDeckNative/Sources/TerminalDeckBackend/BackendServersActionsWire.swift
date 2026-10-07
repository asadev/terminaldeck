import Foundation

extension BackendServersActionPreview {
    private enum WireKeys: String, CodingKey { case actionId, klass, label, target, sentence, wayBack, keeps }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKeys.self)
        try c.encode(actionId, forKey: .actionId); try c.encode(klass, forKey: .klass); try c.encode(label, forKey: .label)
        try c.encode(target, forKey: .target); try c.encode(sentence, forKey: .sentence); try c.encode(wayBack, forKey: .wayBack); try c.encode(keeps, forKey: .keeps)
    }
}
