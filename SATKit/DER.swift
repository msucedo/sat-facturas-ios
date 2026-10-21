// Lector mínimo de DER (ASN.1).
//
// El .cer y el .key de la e.firma son estructuras ASN.1 codificadas en DER:
// cada nodo es [tag][longitud][contenido], y los SEQUENCE/SET contienen más
// nodos. Apple no expone un parser público, así que leemos solo lo necesario.

import Foundation

struct DERNode {
    let tag: UInt8
    let content: Data      // bytes del contenido (sin tag ni longitud)
    let raw: Data          // el nodo completo, tal cual vino

    static let integer: UInt8 = 0x02
    static let octetString: UInt8 = 0x04
    static let null: UInt8 = 0x05
    static let oid: UInt8 = 0x06
    static let utf8String: UInt8 = 0x0C
    static let printableString: UInt8 = 0x13
    static let ia5String: UInt8 = 0x16
    static let utcTime: UInt8 = 0x17
    static let generalizedTime: UInt8 = 0x18
    static let sequence: UInt8 = 0x30
    static let set: UInt8 = 0x31

    var isConstructed: Bool { tag & 0x20 != 0 }

    // Hijos de un SEQUENCE/SET (o de una etiqueta de contexto construida, como [0]).
    func children() throws -> [DERNode] {
        guard isConstructed else { throw DERError.notConstructed }
        var out: [DERNode] = []
        var rest = content[...]
        while !rest.isEmpty {
            let (node, used) = try DERNode.parsePrefix(rest)
            out.append(node)
            rest = rest.dropFirst(used)
        }
        return out
    }

    func child(_ i: Int) throws -> DERNode {
        let c = try children()
        guard i < c.count else { throw DERError.missingChild(i) }
        return c[i]
    }

    static func parse(_ data: Data) throws -> DERNode {
        try parsePrefix(data).0
    }

    // Devuelve el nodo y cuántos bytes ocupó.
    static func parsePrefix(_ data: Data) throws -> (DERNode, Int) {
        let bytes = Array(data)
        guard bytes.count >= 2 else { throw DERError.truncated }
        let tag = bytes[0]
        var length = Int(bytes[1])
        var header = 2
        if length & 0x80 != 0 {
            // Forma larga: los 7 bits bajos dicen cuántos bytes siguen con la longitud.
            let n = length & 0x7F
            guard n >= 1, n <= 4, bytes.count >= 2 + n else { throw DERError.badLength }
            length = 0
            for b in bytes[2..<(2 + n)] { length = (length << 8) | Int(b) }
            header += n
        }
        guard bytes.count >= header + length else { throw DERError.truncated }
        let content = Data(bytes[header..<(header + length)])
        let raw = Data(bytes[0..<(header + length)])
        return (DERNode(tag: tag, content: content, raw: raw), header + length)
    }

    // OID en notación de puntos, p. ej. "2.5.4.45".
    var oidString: String? {
        guard tag == DERNode.oid, let first = content.first else { return nil }
        var parts = [Int(first) / 40, Int(first) % 40]
        var value = 0
        for b in content.dropFirst() {
            value = (value << 7) | Int(b & 0x7F)
            if b & 0x80 == 0 { parts.append(value); value = 0 }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    var stringValue: String? {
        switch tag {
        case DERNode.utf8String, DERNode.printableString, DERNode.ia5String:
            return String(data: content, encoding: .utf8) ?? String(data: content, encoding: .isoLatin1)
        default:
            return nil
        }
    }

    var intValue: Int? {
        guard tag == DERNode.integer, content.count <= 8 else { return nil }
        return content.reduce(0) { ($0 << 8) | Int($1) }
    }

    // UTCTime "YYMMDDhhmmssZ" o GeneralizedTime "YYYYMMDDhhmmssZ".
    var dateValue: Date? {
        guard let s = String(data: content, encoding: .ascii) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        switch tag {
        case DERNode.utcTime: f.dateFormat = "yyMMddHHmmss'Z'"
        case DERNode.generalizedTime: f.dateFormat = "yyyyMMddHHmmss'Z'"
        default: return nil
        }
        return f.date(from: s)
    }
}

enum DERError: Error {
    case truncated, badLength, notConstructed, missingChild(Int)
}
