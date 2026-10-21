// Abrir un paquete de Descarga Masiva (ZIP) y leer lo que traiga: XML de CFDI
// o el .txt de Metadata. Un archivo dañado no tumba el paquete: se anota en errores.

import Foundation

public enum PaqueteSAT {
    public static func leer(_ zip: Data) throws
        -> (cfdis: [(CFDI, Data)], metadata: [RegistroMetadata], errores: [String]) {
        var cfdis: [(CFDI, Data)] = [], metadata: [RegistroMetadata] = [], errores: [String] = []
        for (nombre, datos) in try ZIP.entradas(zip) {
            let ext = (nombre as NSString).pathExtension.lowercased()
            do {
                switch ext {
                case "xml": cfdis.append((try CFDIParser.parse(datos), datos))
                case "txt": metadata += try MetadataParser.parse(datos)
                default: errores.append("\(nombre): tipo de archivo no reconocido.")
                }
            } catch {
                errores.append("\(nombre): \(error)")
            }
        }
        return (cfdis, metadata, errores)
    }
}
