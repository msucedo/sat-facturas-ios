// satctl: pruebas del núcleo SATKit desde la Mac.
//
//   satctl efirma <archivo.cer> <archivo.key>
//   satctl auth <cer> <key> [--debug]
//   satctl solicitar <cer> <key> <emitidos|recibidos> <AAAA-MM> <cfdi|metadata> [--debug]
//   satctl verificar <cer> <key> <IdSolicitud> [--debug]
//   satctl descargar <cer> <key> <IdPaquete> [--debug]      → descargas/<IdPaquete>.zip
//
// Con --debug cada petición y respuesta (tapadas) se guarda en debug/.
//
// La contraseña se pide sin eco (o se toma de SAT_PASSWORD). La e.firma no sale de
// la Mac: solo van al SAT los sobres firmados.

import Foundation
import SATKit

func uso() -> Never {
    print("""
    uso:
      satctl efirma <archivo.cer> <archivo.key>   abre la e.firma y muestra sus datos
      satctl auth <cer> <key> [--debug]            pide un token al SAT
      satctl solicitar <cer> <key> <emitidos|recibidos> <AAAA-MM> <cfdi|metadata> [--debug]
      satctl verificar <cer> <key> <IdSolicitud> [--debug]
      satctl descargar <cer> <key> <IdPaquete> [--debug]   guarda descargas/<IdPaquete>.zip
    """)
    exit(2)
}

func pedirPassword() -> String {
    if let pw = ProcessInfo.processInfo.environment["SAT_PASSWORD"] { return pw }
    guard let p = getpass("Contraseña de la llave privada: ") else { exit(1) }
    return String(cString: p)
}

func cargarEFirma(_ cer: String, _ key: String) throws -> EFirma {
    let cerData = try Data(contentsOf: URL(fileURLWithPath: cer))
    let keyData = try Data(contentsOf: URL(fileURLWithPath: key))
    return try EFirma(cer: cerData, key: keyData, password: pedirPassword())
}

// Cliente con bitácora; con --debug la escribe en debug/<n>_<operación>_request|response.xml.
func cliente(_ cer: String, _ key: String, debug: Bool) throws -> DescargaMasiva {
    let dm = DescargaMasiva(efirma: try cargarEFirma(cer, key))
    var n = 0
    dm.bitacora = { e in
        n += 1
        FileHandle.standardError.write(Data("→ \(e.operacion): HTTP \(e.estadoHTTP.map(String.init) ?? "sin respuesta")\n".utf8))
        guard debug else { return }
        let dir = URL(fileURLWithPath: "debug")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? e.peticion.write(to: dir.appendingPathComponent("\(n)_\(e.operacion)_request.xml"), atomically: true, encoding: .utf8)
        try? e.respuesta.write(to: dir.appendingPathComponent("\(n)_\(e.operacion)_response.xml"), atomically: true, encoding: .utf8)
    }
    return dm
}

var args = Array(CommandLine.arguments.dropFirst())
let debug = args.contains("--debug")
args.removeAll { $0 == "--debug" }
guard let cmd = args.first else { uso() }

do {
    switch cmd {
    case "efirma":
        guard args.count == 3 else { uso() }
        let f = try cargarEFirma(args[1], args[2])
        let c = f.certificado
        let fecha = DateFormatter()
        fecha.dateStyle = .medium
        fecha.locale = Locale(identifier: "es_MX")
        print("RFC:            \(c.rfc)")
        print("Nombre:         \(c.nombre)")
        print("No. certificado: \(c.noCertificado)")
        print("Vigencia:       \(fecha.string(from: c.validoDesde)) → \(fecha.string(from: c.validoHasta))\(c.vigente ? "" : "  ⚠️ VENCIDA")")
        print("Llave:          OK, es la pareja del certificado")
    case "auth":
        guard args.count == 3 else { uso() }
        let t = try await cliente(args[1], args[2], debug: debug).autenticar()
        print("Token: \(t.valor.prefix(20))…  (vence \(t.expira))")
    case "solicitar":
        guard args.count == 6, let tipo = TipoDescarga(rawValue: args[3].capitalized),
              let sol = TipoSolicitud.allCases.first(where: { $0.rawValue.lowercased() == args[5].lowercased() })
        else { uso() }
        let am = args[4].split(separator: "-").compactMap { Int($0) }
        guard am.count == 2, (1...12).contains(am[1]) else { uso() }
        let id = try await cliente(args[1], args[2], debug: debug).solicitar(tipo, .mes(am[0], am[1]), sol)
        print("IdSolicitud: \(id)")
    case "verificar":
        guard args.count == 4 else { uso() }
        let v = try await cliente(args[1], args[2], debug: debug).verificar(args[3])
        print("Estado:      \(v.estado) (CodigoEstadoSolicitud \(v.codigoEstadoSolicitud))")
        print("CFDI:        \(v.numeroCFDIs)")
        print("Mensaje:     \(v.mensaje)")
        for p in v.paquetes { print("Paquete:     \(p)") }
    case "descargar":
        guard args.count == 4 else { uso() }
        let zip = try await cliente(args[1], args[2], debug: debug).descargar(paquete: args[3])
        let dir = URL(fileURLWithPath: "descargas")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destino = dir.appendingPathComponent("\(args[3]).zip")
        try zip.write(to: destino)
        print("Guardado: \(destino.path) (\(zip.count) bytes)")
    default:
        uso()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
