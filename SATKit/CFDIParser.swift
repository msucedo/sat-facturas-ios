// Lector de CFDI (XML) 4.0 y 3.3; también lo básico de 3.2.
//
// Usamos XMLParser sin procesar namespaces: comparamos nombres locales (sin el
// prefijo cfdi:, tfd:, etc.). Solo nos interesa lo que va a la tabla: datos
// del Comprobante, Emisor, Receptor, Conceptos, el bloque global de Impuestos
// (hijo directo del Comprobante; los de cada concepto se ignoran para no contar
// doble) y el UUID del TimbreFiscalDigital. El resto de complementos se ignora.

import Foundation

public enum CFDIError: Error, CustomStringConvertible, Sendable {
    case noEsCFDI
    case sinUUID
    case campo(String)

    public var description: String {
        switch self {
        case .noEsCFDI: return "El XML no es un CFDI."
        case .sinUUID: return "El CFDI no está timbrado (no tiene UUID)."
        case .campo(let c): return "El CFDI tiene el campo \(c) vacío o inválido."
        }
    }
}

public enum CFDIParser {
    public static func parse(_ xml: Data) throws -> CFDI {
        let lector = Lector()
        let p = XMLParser(data: xml)
        p.shouldProcessNamespaces = false
        p.delegate = lector
        guard p.parse(), let c = lector.comprobante else { throw lector.error ?? CFDIError.noEsCFDI }

        func req(_ k: String) throws -> String {
            guard let v = c[k.lowercased()], !v.isEmpty else { throw CFDIError.campo(k) }
            return v
        }
        func dec(_ k: String, requerido: Bool = true) throws -> Decimal {
            guard let v = c[k.lowercased()], !v.isEmpty else {
                if requerido { throw CFDIError.campo(k) }; return 0
            }
            guard let d = decimal(v) else { throw CFDIError.campo(k) }
            return d
        }

        let version = try req("Version")
        guard let fecha = fechaCFDI.date(from: try req("Fecha")) else { throw CFDIError.campo("Fecha") }
        guard let uuid = lector.uuid, !uuid.isEmpty else { throw CFDIError.sinUUID }
        guard let em = lector.emisor, let emRfc = em["rfc"], !emRfc.isEmpty else { throw CFDIError.campo("Emisor") }
        guard let re = lector.receptor, let reRfc = re["rfc"], !reRfc.isEmpty else { throw CFDIError.campo("Receptor") }

        var tipo = try req("TipoDeComprobante")
        switch tipo.lowercased() {   // 3.2 usaba palabras
        case "ingreso": tipo = "I"
        case "egreso": tipo = "E"
        case "traslado": tipo = "T"
        default: break
        }

        let conceptos = try lector.conceptos.map { a -> Concepto in
            guard let cant = decimal(a["cantidad"] ?? ""), let imp = decimal(a["importe"] ?? "")
            else { throw CFDIError.campo("Concepto") }
            return Concepto(descripcion: a["descripcion"] ?? "", cantidad: cant, importe: imp)
        }

        return CFDI(
            uuid: uuid.uppercased(), version: version, fecha: fecha,
            serie: vacioANil(c["serie"]), folio: vacioANil(c["folio"]), tipoComprobante: tipo,
            emisor: Parte(rfc: emRfc, nombre: em["nombre"] ?? "", regimenFiscal: vacioANil(em["regimenfiscal"])),
            receptor: Parte(rfc: reRfc, nombre: re["nombre"] ?? "",
                            regimenFiscal: vacioANil(re["regimenfiscalreceptor"]), usoCFDI: vacioANil(re["usocfdi"])),
            subTotal: try dec("SubTotal"), descuento: try dec("Descuento", requerido: false),
            total: try dec("Total"), moneda: vacioANil(c["moneda"]) ?? "MXN",
            formaPago: vacioANil(c["formapago"]), metodoPago: vacioANil(c["metodopago"]),
            ivaTrasladado: lector.ivaTrasladado, isrRetenido: lector.isrRetenido,
            ivaRetenido: lector.ivaRetenido, conceptos: conceptos)
    }

    static func decimal(_ s: String) -> Decimal? {
        Decimal(string: s.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func vacioANil(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    static let fechaCFDI: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = Periodo.zona
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    // Atributos con nombres en minúsculas y sin prefijo (3.2 los usaba en minúsculas).
    private typealias Attrs = [String: String]

    private final class Lector: NSObject, XMLParserDelegate {
        var ruta: [String] = []
        var comprobante: Attrs?
        var emisor: Attrs?
        var receptor: Attrs?
        var conceptos: [Attrs] = []
        var uuid: String?
        var ivaTrasladado: Decimal = 0, isrRetenido: Decimal = 0, ivaRetenido: Decimal = 0
        var error: Error?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let nombre = local(elementName)
            var a: Attrs = [:]
            for (k, v) in attributeDict where !k.hasPrefix("xmlns") { a[local(k).lowercased()] = v }

            if ruta.isEmpty, nombre != "Comprobante" {
                error = CFDIError.noEsCFDI; parser.abortParsing(); return
            }
            ruta.append(nombre)
            switch ruta {
            case ["Comprobante"]: comprobante = a
            case ["Comprobante", "Emisor"]: emisor = a
            case ["Comprobante", "Receptor"]: receptor = a
            case ["Comprobante", "Conceptos", "Concepto"]: conceptos.append(a)
            case ["Comprobante", "Impuestos", "Traslados", "Traslado"]:
                if impuesto(a) == "002" { ivaTrasladado += importe(a) }
            case ["Comprobante", "Impuestos", "Retenciones", "Retencion"]:
                switch impuesto(a) {
                case "001": isrRetenido += importe(a)
                case "002": ivaRetenido += importe(a)
                default: break
                }
            case ["Comprobante", "Complemento", "TimbreFiscalDigital"]: uuid = a["uuid"]
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            ruta.removeLast()
        }

        private func local(_ s: String) -> String { s.split(separator: ":").last.map(String.init) ?? s }

        // 3.2 decía "IVA"/"ISR" en vez de la clave.
        private func impuesto(_ a: Attrs) -> String {
            switch a["impuesto"]?.uppercased() {
            case "IVA": return "002"
            case "ISR": return "001"
            case let v?: return v
            case nil: return ""
            }
        }

        // Sin Importe (p. ej. TipoFactor Exento) cuenta como 0.
        private func importe(_ a: Attrs) -> Decimal { a["importe"].flatMap(CFDIParser.decimal) ?? 0 }
    }
}
