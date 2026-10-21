// Lector del archivo de Metadata del SAT (.txt dentro del paquete).
//
// Primera línea: encabezado; campos separados por "~"; líneas CRLF o LF.
// Columnas v1.5: Uuid~RfcEmisor~NombreEmisor~RfcReceptor~NombreReceptor~RfcPac~
// FechaEmision~FechaCertificacionSat~Monto~EfectoComprobante~Estatus~FechaCancelacion
// (a veces con RfcACuentaTerceros / NombreACuentaTerceros). Las leemos por
// nombre, así que el orden y las columnas extra no importan.

import Foundation

public enum MetadataError: Error, CustomStringConvertible, Sendable {
    case sinEncabezado

    public var description: String {
        switch self {
        case .sinEncabezado: return "El archivo de Metadata no tiene el encabezado esperado (Uuid~RfcEmisor~…)."
        }
    }
}

public enum MetadataParser {
    public static func parse(_ txt: Data) throws -> [RegistroMetadata] {
        var d = txt
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }
        // UTF-8; si no lo es, ISO Latin-1 (nunca falla).
        let texto = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""

        var lineas = texto.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lineas.isEmpty else { throw MetadataError.sinEncabezado }

        // Índice de cada columna por nombre, sin distinguir mayúsculas.
        var col: [String: Int] = [:]
        for (i, n) in campos(lineas.removeFirst()).enumerated() {
            col[n.trimmingCharacters(in: .whitespaces).lowercased()] = i
        }
        guard let iUuid = col["uuid"] else { throw MetadataError.sinEncabezado }
        let necesarias = [iUuid, col["rfcemisor"], col["rfcreceptor"]].compactMap { $0 }
        let minimo = (necesarias.max() ?? iUuid) + 1

        return lineas.compactMap { linea in
            let f = campos(linea)
            guard f.count >= minimo else { return nil }   // línea incompleta: se salta
            func v(_ k: String) -> String {
                guard let i = col[k], i < f.count else { return "" }
                return f[i].trimmingCharacters(in: .whitespaces)
            }
            let uuid = v("uuid")
            guard !uuid.isEmpty else { return nil }
            return RegistroMetadata(
                uuid: uuid.uppercased(), rfcEmisor: v("rfcemisor"), nombreEmisor: v("nombreemisor"),
                rfcReceptor: v("rfcreceptor"), nombreReceptor: v("nombrereceptor"),
                fechaEmision: fecha.date(from: v("fechaemision")),
                monto: CFDIParser.decimal(v("monto")) ?? 0, efecto: v("efectocomprobante"),
                vigente: v("estatus") != "0", fechaCancelacion: fecha.date(from: v("fechacancelacion")))
        }
    }

    private static func campos(_ linea: String) -> [String] {
        linea.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
    }

    static let fecha: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = Periodo.zona
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
