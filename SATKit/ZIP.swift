// Lector y escritor mínimo de ZIP.
//
// Los paquetes de Descarga Masiva llegan como ZIP (en base64). Leemos el
// directorio central (al final del archivo), y de cada entrada sacamos los datos
// desde su encabezado local. Métodos 0 (sin comprimir) y 8 (deflate). ZIP64 se
// lee si viene (tamaños y offsets de 64 bits). Para exportar escribimos ZIP sin
// comprimir: los XML ya son pequeños y así no dependemos de nada.

import Foundation
import Compression

public enum ZIPError: Error, CustomStringConvertible, Sendable {
    case noEsZIP
    case truncado
    case metodoNoSoportado(String, Int)
    case cifrado(String)
    case descompresion(String)
    case crc(String)

    public var description: String {
        switch self {
        case .noEsZIP: return "El archivo no es un ZIP válido."
        case .truncado: return "El ZIP está incompleto o dañado."
        case .metodoNoSoportado(let n, let m): return "\(n): método de compresión \(m) no soportado."
        case .cifrado(let n): return "\(n): el archivo está cifrado."
        case .descompresion(let n): return "\(n): no se pudo descomprimir."
        case .crc(let n): return "\(n): el CRC no coincide (archivo dañado)."
        }
    }
}

public enum ZIP {
    // MARK: Leer

    /// Todas las entradas (sin directorios), en el orden del directorio central.
    public static func entradas(_ data: Data) throws -> [(nombre: String, datos: Data)] {
        let b = [UInt8](data)
        let eocd = try finDirectorio(b)
        var total = Int(u16(b, eocd + 10))
        var tamCD = UInt64(u32(b, eocd + 12))
        var inicioCD = UInt64(u32(b, eocd + 16))

        // ZIP64: el localizador va justo antes del EOCD.
        if total == 0xFFFF || tamCD == 0xFFFF_FFFF || inicioCD == 0xFFFF_FFFF,
           eocd >= 20, u32(b, eocd - 20) == 0x0706_4b50 {
            let off = Int(clamping: u64(b, eocd - 20 + 8))
            guard off + 56 <= b.count, u32(b, off) == 0x0606_4b50 else { throw ZIPError.truncado }
            total = Int(clamping: u64(b, off + 32))
            tamCD = u64(b, off + 40)
            inicioCD = u64(b, off + 48)
        }
        guard inicioCD + tamCD <= UInt64(b.count) else { throw ZIPError.truncado }

        var out: [(nombre: String, datos: Data)] = []
        var p = Int(inicioCD)
        for _ in 0..<total {
            guard p + 46 <= b.count, u32(b, p) == 0x0201_4b50 else { throw ZIPError.truncado }
            let flags = u16(b, p + 8)
            let metodo = Int(u16(b, p + 10))
            let crc = u32(b, p + 16)
            var comp = UInt64(u32(b, p + 20))
            var descomp = UInt64(u32(b, p + 24))
            let nLen = Int(u16(b, p + 28)), eLen = Int(u16(b, p + 30)), cLen = Int(u16(b, p + 32))
            var local = UInt64(u32(b, p + 42))
            guard p + 46 + nLen + eLen + cLen <= b.count else { throw ZIPError.truncado }
            let nombreBytes = Array(b[(p + 46)..<(p + 46 + nLen)])
            let nombre = flags & 0x800 != 0
                ? String(decoding: nombreBytes, as: UTF8.self)
                : (String(bytes: nombreBytes, encoding: .utf8) ?? String(bytes: nombreBytes, encoding: .isoLatin1) ?? "")

            // Campo extra ZIP64 (0x0001): solo trae los valores que valen 0xFFFFFFFF, en orden.
            var e = p + 46 + nLen
            let finExtra = e + eLen
            while e + 4 <= finExtra {
                let id = u16(b, e), len = Int(u16(b, e + 2))
                if id == 0x0001 {
                    var q = e + 4
                    if descomp == 0xFFFF_FFFF, q + 8 <= e + 4 + len { descomp = u64(b, q); q += 8 }
                    if comp == 0xFFFF_FFFF, q + 8 <= e + 4 + len { comp = u64(b, q); q += 8 }
                    if local == 0xFFFF_FFFF, q + 8 <= e + 4 + len { local = u64(b, q); q += 8 }
                }
                e += 4 + len
            }
            p += 46 + nLen + eLen + cLen

            if nombre.hasSuffix("/") { continue }
            if flags & 1 != 0 { throw ZIPError.cifrado(nombre) }

            // Encabezado local: su nombre/extra pueden medir distinto que en el central.
            let l = Int(clamping: local)
            guard l + 30 <= b.count, u32(b, l) == 0x0403_4b50 else { throw ZIPError.truncado }
            let ini = l + 30 + Int(u16(b, l + 26)) + Int(u16(b, l + 28))
            guard comp <= UInt64(b.count), ini + Int(comp) <= b.count else { throw ZIPError.truncado }
            let crudo = Data(b[ini..<(ini + Int(comp))])

            let datos: Data
            switch metodo {
            case 0: datos = crudo
            case 8: datos = try inflar(crudo, tamaño: Int(clamping: descomp), nombre: nombre)
            default: throw ZIPError.metodoNoSoportado(nombre, metodo)
            }
            guard UInt64(datos.count) == descomp else { throw ZIPError.descompresion(nombre) }
            guard crc32(datos) == crc else { throw ZIPError.crc(nombre) }
            out.append((nombre, datos))
        }
        return out
    }

    // Busca la firma del EOCD hacia atrás (puede haber un comentario de hasta 64 KB).
    private static func finDirectorio(_ b: [UInt8]) throws -> Int {
        guard b.count >= 22 else { throw ZIPError.noEsZIP }
        let limite = max(0, b.count - 22 - 0xFFFF)
        var i = b.count - 22
        while i >= limite {
            if b[i] == 0x50, b[i + 1] == 0x4b, b[i + 2] == 0x05, b[i + 3] == 0x06,
               i + 22 + Int(u16(b, i + 20)) <= b.count { return i }
            i -= 1
        }
        throw ZIPError.noEsZIP
    }

    // Deflate crudo (sin encabezado zlib), que es lo que COMPRESSION_ZLIB espera.
    private static func inflar(_ d: Data, tamaño: Int, nombre: String) throws -> Data {
        if tamaño == 0 { return Data() }
        var out = Data(count: tamaño)
        let n = out.withUnsafeMutableBytes { dst in
            d.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, tamaño,
                                          src.bindMemory(to: UInt8.self).baseAddress!, d.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard n == tamaño else { throw ZIPError.descompresion(nombre) }
        return out
    }

    // MARK: Escribir

    /// ZIP sin comprimir (método 0), nombres en UTF-8, con la fecha y hora actuales.
    public static func crear(_ archivos: [(nombre: String, datos: Data)]) -> Data {
        let (hora, fecha) = fechaDOS(Date())
        var out = Data(), central = Data()
        for a in archivos {
            let nombre = Data(a.nombre.utf8)
            let crc = crc32(a.datos)
            let offset = UInt32(out.count)
            // Encabezado local
            out.le32(0x0403_4b50); out.le16(20); out.le16(0x800); out.le16(0)
            out.le16(hora); out.le16(fecha); out.le32(crc)
            out.le32(UInt32(a.datos.count)); out.le32(UInt32(a.datos.count))
            out.le16(UInt16(nombre.count)); out.le16(0)
            out.append(nombre); out.append(a.datos)
            // Entrada del directorio central
            central.le32(0x0201_4b50); central.le16(20); central.le16(20); central.le16(0x800); central.le16(0)
            central.le16(hora); central.le16(fecha); central.le32(crc)
            central.le32(UInt32(a.datos.count)); central.le32(UInt32(a.datos.count))
            central.le16(UInt16(nombre.count)); central.le16(0); central.le16(0)
            central.le16(0); central.le16(0); central.le32(0); central.le32(offset)
            central.append(nombre)
        }
        let inicioCD = UInt32(out.count)
        out.append(central)
        out.le32(0x0605_4b50); out.le16(0); out.le16(0)
        out.le16(UInt16(archivos.count)); out.le16(UInt16(archivos.count))
        out.le32(UInt32(central.count)); out.le32(inicioCD); out.le16(0)
        return out
    }

    private static func fechaDOS(_ d: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: d)
        let hora = UInt16(c.hour! << 11 | c.minute! << 5 | c.second! / 2)
        let fecha = UInt16(max(0, c.year! - 1980) << 9 | c.month! << 5 | c.day!)
        return (hora, fecha)
    }

    // MARK: CRC32 (polinomio 0xEDB88320)

    private static let tablaCRC: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        d.withUnsafeBytes { for x in $0 { c = tablaCRC[Int((c ^ UInt32(x)) & 0xFF)] ^ (c >> 8) } }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: Little endian

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    private static func u64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(u32(b, i)) | UInt64(u32(b, i + 4)) << 32 }
}

private extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
