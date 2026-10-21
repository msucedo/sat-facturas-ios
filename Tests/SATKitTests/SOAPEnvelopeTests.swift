import XCTest
@testable import SATKit

final class SOAPEnvelopeTests: XCTestCase {
    let creado = Date(timeIntervalSince1970: 1_792_607_400)   // 2026-10-21 18:30:00Z
    let uuid = UUID(uuidString: "0F8C2A4E-1B3D-4E5F-8A9B-123456789ABC")!

    func sobre() throws -> String {
        try SOAPEnvelope.autenticacion(efirma: efirma(), creado: creado, uuid: uuid)
    }

    // Texto entre `<etiqueta ...>` y `</etiqueta>` (basta para estas pruebas).
    func contenido(_ etiqueta: String, en xml: String) throws -> String {
        let abre = try XCTUnwrap(xml.range(of: "<\(etiqueta)"))
        let fin = try XCTUnwrap(xml.range(of: ">", range: abre.upperBound..<xml.endIndex))
        let cierra = try XCTUnwrap(xml.range(of: "</\(etiqueta)>", range: fin.upperBound..<xml.endIndex))
        return String(xml[fin.upperBound..<cierra.lowerBound])
    }

    func testTimestampYToken() throws {
        let xml = try sobre()
        XCTAssertTrue(xml.contains("<u:Created>2026-10-21T18:30:00.000Z</u:Created><u:Expires>2026-10-21T18:35:00.000Z</u:Expires>"))
        XCTAssertTrue(xml.contains("u:Id=\"uuid-0f8c2a4e-1b3d-4e5f-8a9b-123456789abc-4\""))
        XCTAssertTrue(xml.contains("URI=\"#uuid-0f8c2a4e-1b3d-4e5f-8a9b-123456789abc-4\""))
        XCTAssertEqual(try contenido("o:BinarySecurityToken", en: xml), try fixture("EKU9003173C9.cer").base64EncodedString())
        XCTAssertTrue(xml.hasSuffix("<s:Body><Autentica xmlns=\"http://DescargaMasivaTerceros.gob.mx\"/></s:Body></s:Envelope>"))
    }

    // El Timestamp canónico, escrito a mano, y su SHA1 calculado con
    // `printf '%s' '<u:Timestamp…' | openssl dgst -sha1 -binary | base64`.
    func testDigestDelTimestamp() throws {
        let esperado = "<u:Timestamp xmlns:u=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd\" u:Id=\"_0\"><u:Created>2026-10-21T18:30:00.000Z</u:Created><u:Expires>2026-10-21T18:35:00.000Z</u:Expires></u:Timestamp>"
        XCTAssertEqual(SOAPEnvelope.timestampCanonico(creado: creado), esperado)
        XCTAssertTrue(try sobre().contains(esperado))
        XCTAssertEqual(try contenido("DigestValue", en: sobre()), "ftD9LyCO318NRm7KRjgjLd6dqvE=")
    }

    func testFirmaSeVerificaConElCertificado() throws {
        let xml = try sobre()
        let inicio = try XCTUnwrap(xml.range(of: "<SignedInfo"))
        let fin = try XCTUnwrap(xml.range(of: "</SignedInfo>"))
        let signedInfo = Data(xml[inicio.lowerBound..<fin.upperBound].utf8)
        let firma = try XCTUnwrap(Data(base64Encoded: contenido("SignatureValue", en: xml)))
        let pub = try XCTUnwrap(efirma().certificado.llavePublica)
        XCTAssertTrue(SecKeyVerifySignature(pub, .rsaSignatureMessagePKCS1v15SHA1,
                                            signedInfo as CFData, firma as CFData, nil))
    }

    // RSA PKCS#1 v1.5 es determinista: mismas entradas → mismo sobre.
    // Con SOBRE_SALIDA=<ruta> además lo guarda, para revisarlo con herramientas externas.
    func testDeterminista() throws {
        let a = try sobre(), b = try sobre()
        XCTAssertEqual(a, b)
        if let ruta = ProcessInfo.processInfo.environment["SOBRE_SALIDA"] {
            try a.write(toFile: ruta, atomically: true, encoding: .utf8)
        }
    }

    // MARK: firma envuelta (solicitud, verificación, descarga)

    let septiembre = Periodo.mes(2026, 9)

    func sobresEnvueltos() throws -> [(nombre: String, elemento: String, xml: String)] {
        let f = try efirma()
        var out: [(String, String, String)] = []
        for t in TipoDescarga.allCases {
            for s in TipoSolicitud.allCases {
                out.append(("solicitud_\(t.rawValue.lowercased())_\(s.rawValue.lowercased())", "des:solicitud",
                            try SOAPEnvelope.solicitud(efirma: f, tipo: t, periodo: septiembre, solicitud: s)))
            }
        }
        out.append(("verificacion", "des:solicitud",
                    try SOAPEnvelope.verificacion(efirma: f, idSolicitud: "4e80345d-917f-40bb-a98f-4a73939343c5")))
        out.append(("descarga", "des:peticionDescarga",
                    try SOAPEnvelope.descarga(efirma: f, idPaquete: "4E80345D-917F-40BB-A98F-4A73939343C5_01")))
        return out
    }

    // El elemento firmado tal como va en el sobre, y el mismo sin la Signature
    // (lo que da exc-c14n tras el transform enveloped-signature).
    func elementoFirmado(_ etiqueta: String, en xml: String) throws -> (conFirma: String, sinFirma: String) {
        let abre = try XCTUnwrap(xml.range(of: "<\(etiqueta) "))
        let cierra = try XCTUnwrap(xml.range(of: "</\(etiqueta)>", range: abre.upperBound..<xml.endIndex))
        let el = String(xml[abre.lowerBound..<cierra.upperBound])
        let fi = try XCTUnwrap(el.range(of: "<Signature xmlns="))
        let ff = try XCTUnwrap(el.range(of: "</Signature>"))
        var sin = el
        sin.removeSubrange(fi.lowerBound..<ff.upperBound)
        return (el, sin)
    }

    func testFirmaEnvueltaSeVerifica() throws {
        let pub = try XCTUnwrap(efirma().certificado.llavePublica)
        for (nombre, etiqueta, xml) in try sobresEnvueltos() {
            let (_, sin) = try elementoFirmado(etiqueta, en: xml)
            XCTAssertEqual(try contenido("DigestValue", en: xml), SOAPEnvelope.digestSHA1(sin), nombre)
            let inicio = try XCTUnwrap(xml.range(of: "<SignedInfo"))
            let fin = try XCTUnwrap(xml.range(of: "</SignedInfo>"))
            let signedInfo = Data(xml[inicio.lowerBound..<fin.upperBound].utf8)
            let firma = try XCTUnwrap(Data(base64Encoded: contenido("SignatureValue", en: xml)))
            XCTAssertTrue(SecKeyVerifySignature(pub, .rsaSignatureMessagePKCS1v15SHA1,
                                                signedInfo as CFData, firma as CFData, nil), nombre)
            XCTAssertTrue(xml.contains("<Reference URI=\"\"><Transforms><Transform Algorithm=\"http://www.w3.org/2000/09/xmldsig#enveloped-signature\"></Transform><Transform Algorithm=\"http://www.w3.org/2001/10/xml-exc-c14n#\"></Transform></Transforms>"), nombre)
            XCTAssertEqual(try contenido("X509Certificate", en: xml), try fixture("EKU9003173C9.cer").base64EncodedString())
            XCTAssertEqual(try contenido("X509SerialNumber", en: xml), try efirma().certificado.serialDecimal)
            XCTAssertTrue(xml.hasPrefix("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:des=\"http://DescargaMasivaTerceros.sat.gob.mx\"><s:Header></s:Header><s:Body>"))
            XCTAssertEqual(xml, try sobresEnvueltos().first { $0.nombre == nombre }?.xml, "determinista")
        }
    }

    // El canónico escrito a mano: xmlns:des en el elemento, atributos en orden, sin RfcSolicitante.
    func testSolicitudEmitidos() throws {
        let xml = try SOAPEnvelope.solicitud(efirma: efirma(), tipo: .emitidos, periodo: septiembre, solicitud: .cfdi)
        XCTAssertEqual(try elementoFirmado("des:solicitud", en: xml).sinFirma,
            "<des:solicitud xmlns:des=\"http://DescargaMasivaTerceros.sat.gob.mx\" EstadoComprobante=\"Todos\" FechaFinal=\"2026-09-30T23:59:59\" FechaInicial=\"2026-09-01T00:00:00\" RfcEmisor=\"EKU9003173C9\" TipoSolicitud=\"CFDI\"></des:solicitud>")
        XCTAssertTrue(xml.contains("<s:Body><des:SolicitaDescargaEmitidos><des:solicitud "))
        XCTAssertFalse(xml.contains("RfcSolicitante"))
        XCTAssertFalse(xml.contains("RfcReceptor"))
    }

    func testSolicitudRecibidos() throws {
        let f = try efirma()
        let cfdi = try SOAPEnvelope.solicitud(efirma: f, tipo: .recibidos, periodo: septiembre, solicitud: .cfdi)
        XCTAssertEqual(try elementoFirmado("des:solicitud", en: cfdi).sinFirma,
            "<des:solicitud xmlns:des=\"http://DescargaMasivaTerceros.sat.gob.mx\" EstadoComprobante=\"Vigente\" FechaFinal=\"2026-09-30T23:59:59\" FechaInicial=\"2026-09-01T00:00:00\" RfcReceptor=\"EKU9003173C9\" TipoSolicitud=\"CFDI\"><des:RfcReceptores><des:RfcReceptor>EKU9003173C9</des:RfcReceptor></des:RfcReceptores></des:solicitud>")
        XCTAssertTrue(cfdi.contains("<s:Body><des:SolicitaDescargaRecibidos><des:solicitud "))
        let meta = try SOAPEnvelope.solicitud(efirma: f, tipo: .recibidos, periodo: septiembre, solicitud: .metadata)
        XCTAssertTrue(meta.contains("EstadoComprobante=\"Todos\""))
        XCTAssertTrue(meta.contains("TipoSolicitud=\"Metadata\""))
        let emiMeta = try SOAPEnvelope.solicitud(efirma: f, tipo: .emitidos, periodo: septiembre, solicitud: .metadata)
        XCTAssertTrue(emiMeta.contains("EstadoComprobante=\"Todos\""))
    }

    func testVerificacionYDescarga() throws {
        let f = try efirma()
        let v = try SOAPEnvelope.verificacion(efirma: f, idSolicitud: "abc")
        XCTAssertEqual(try elementoFirmado("des:solicitud", en: v).sinFirma,
            "<des:solicitud xmlns:des=\"http://DescargaMasivaTerceros.sat.gob.mx\" IdSolicitud=\"abc\" RfcSolicitante=\"EKU9003173C9\"></des:solicitud>")
        XCTAssertTrue(v.contains("<s:Body><des:VerificaSolicitudDescarga><des:solicitud "))
        let d = try SOAPEnvelope.descarga(efirma: f, idPaquete: "P_01")
        XCTAssertEqual(try elementoFirmado("des:peticionDescarga", en: d).sinFirma,
            "<des:peticionDescarga xmlns:des=\"http://DescargaMasivaTerceros.sat.gob.mx\" IdPaquete=\"P_01\" RfcSolicitante=\"EKU9003173C9\"></des:peticionDescarga>")
        XCTAssertTrue(d.contains("<s:Body><des:PeticionDescargaMasivaTercerosEntrada><des:peticionDescarga "))
    }

    // Con SOBRE_DIR=<carpeta> guarda todos los sobres para tools/verifica_sobre.py.
    func testGuardaSobres() throws {
        guard let dir = ProcessInfo.processInfo.environment["SOBRE_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try sobre().write(toFile: "\(dir)/autenticacion.xml", atomically: true, encoding: .utf8)
        for (nombre, _, xml) in try sobresEnvueltos() {
            try xml.write(toFile: "\(dir)/\(nombre).xml", atomically: true, encoding: .utf8)
        }
    }
}
