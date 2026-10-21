// Exportar CFDI a CSV (para Excel/Numbers) y empacar XML en un ZIP.

import Foundation

public enum Exportar {
    public static let columnas = [
        "UUID", "Fecha", "Tipo", "Serie", "Folio", "RFC Emisor", "Emisor", "RFC Receptor", "Receptor",
        "Uso CFDI", "Subtotal", "Descuento", "IVA trasladado", "ISR retenido", "IVA retenido", "Total",
        "Moneda", "Forma de pago", "Método de pago",
    ]

    /// CSV UTF-8 con BOM (para que Excel respete los acentos), comas y comillas según RFC 4180.
    public static func csv(_ cfdis: [CFDI]) -> Data {
        var s = "\u{FEFF}" + columnas.map(campo).joined(separator: ",") + "\r\n"
        for c in cfdis {
            let fila: [String] = [
                c.uuid, fecha.string(from: c.fecha), c.tipoComprobante, c.serie ?? "", c.folio ?? "",
                c.emisor.rfc, c.emisor.nombre, c.receptor.rfc, c.receptor.nombre, c.receptor.usoCFDI ?? "",
                importe(c.subTotal), importe(c.descuento), importe(c.ivaTrasladado), importe(c.isrRetenido),
                importe(c.ivaRetenido), importe(c.total), c.moneda, c.formaPago ?? "", c.metodoPago ?? "",
            ]
            s += fila.map(campo).joined(separator: ",") + "\r\n"
        }
        return Data(s.utf8)
    }

    /// ZIP sin comprimir con los archivos tal cual.
    public static func zip(_ archivos: [(nombre: String, datos: Data)]) -> Data { ZIP.crear(archivos) }

    // Entre comillas si trae coma, comillas o salto de línea; las comillas se duplican.
    private static func campo(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func importe(_ d: Decimal) -> String { numero.string(from: d as NSDecimalNumber) ?? "\(d)" }

    private static let numero: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.roundingMode = .halfUp
        return f
    }()

    private static let fecha: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = Periodo.zona
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
