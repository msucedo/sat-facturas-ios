import XCTest
@testable import SATKit

// Respuestas del SAT escritas a mano según el formato documentado. Nada sale a la red.
final class SATFalso: URLProtocol {
    struct Peticion { let url: URL; let headers: [String: String]; let cuerpo: String }
    static var peticiones: [Peticion] = []
    /// SOAPAction (sin comillas) → (HTTP, cuerpo)
    static var respuestas: [String: (Int, String)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession pasa el cuerpo como stream.
        var cuerpo = request.httpBody ?? Data()
        if cuerpo.isEmpty, let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; cuerpo.append(buf, count: n) }
            s.close()
        }
        let headers = request.allHTTPHeaderFields ?? [:]
        Self.peticiones.append(Peticion(url: request.url!, headers: headers, cuerpo: String(decoding: cuerpo, as: UTF8.self)))
        let accion = (headers["SOAPAction"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let (estado, texto) = Self.respuestas[accion] ?? (404, "no hay respuesta para \(accion)")
        let resp = HTTPURLResponse(url: request.url!, statusCode: estado, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/xml; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(texto.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DescargaMasivaTests: XCTestCase {
    let autentica = "http://DescargaMasivaTerceros.gob.mx/IAutenticacion/Autentica"
    let solicitaEmitidos = "http://DescargaMasivaTerceros.sat.gob.mx/ISolicitaDescargaService/SolicitaDescargaEmitidos"
    let solicitaRecibidos = "http://DescargaMasivaTerceros.sat.gob.mx/ISolicitaDescargaService/SolicitaDescargaRecibidos"
    let verifica = "http://DescargaMasivaTerceros.sat.gob.mx/IVerificaSolicitudDescargaService/VerificaSolicitudDescarga"
    let descarga = "http://DescargaMasivaTerceros.sat.gob.mx/IDescargaMasivaTercerosService/Descargar"

    var ahora = Date(timeIntervalSince1970: 1_792_607_400)
    var entradas: [EntradaBitacora] = []

    func cliente() throws -> DescargaMasiva {
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [SATFalso.self]
        let dm = DescargaMasiva(efirma: try efirma(), session: URLSession(configuration: conf)) { [unowned self] in self.ahora }
        dm.bitacora = { [unowned self] in self.entradas.append($0) }
        return dm
    }

    override func setUp() {
        SATFalso.peticiones = []
        SATFalso.respuestas = [autentica: (200, Self.authOK("TOKEN-1"))]
        entradas = []
    }

    static func authOK(_ token: String) -> String {
        """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" xmlns:u="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><s:Header><o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><u:Timestamp u:Id="_0"><u:Created>2026-10-21T18:30:00.000Z</u:Created><u:Expires>2026-10-21T18:35:00.000Z</u:Expires></u:Timestamp></o:Security></s:Header><s:Body><AutenticaResponse xmlns="http://DescargaMasivaTerceros.gob.mx"><AutenticaResult>\(token)</AutenticaResult></AutenticaResponse></s:Body></s:Envelope>
        """
    }

    static func solicitudResp(_ cod: Int, _ id: String, _ msg: String) -> String {
        """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema"><SolicitaDescargaEmitidosResponse xmlns="http://DescargaMasivaTerceros.sat.gob.mx"><SolicitaDescargaEmitidosResult IdSolicitud="\(id)" RfcSolicitante="EKU9003173C9" CodEstatus="\(cod)" Mensaje="\(msg)"/></SolicitaDescargaEmitidosResponse></s:Body></s:Envelope>
        """
    }

    func testAutenticarReusaElToken() async throws {
        let dm = try cliente()
        let a = try await dm.autenticar()
        XCTAssertEqual(a.valor, "TOKEN-1")
        XCTAssertEqual(a.expira, ahora.addingTimeInterval(300))
        SATFalso.respuestas[autentica] = (200, Self.authOK("TOKEN-2"))
        ahora += 120
        let b = try await dm.autenticar()
        XCTAssertEqual(b.valor, "TOKEN-1")
        XCTAssertEqual(SATFalso.peticiones.count, 1)
        ahora += 200   // ya pasaron más de 5 min
        let c = try await dm.autenticar()
        XCTAssertEqual(c.valor, "TOKEN-2")
        XCTAssertEqual(SATFalso.peticiones.count, 2)

        let p = SATFalso.peticiones[0]
        XCTAssertEqual(p.url.absoluteString, "https://cfdidescargamasivasolicitud.clouda.sat.gob.mx/Autenticacion/Autenticacion.svc")
        XCTAssertEqual(p.headers["SOAPAction"], "\"\(autentica)\"")
        XCTAssertNil(p.headers["Authorization"])
        XCTAssertEqual(p.headers["Content-Type"], "text/xml; charset=utf-8")
        XCTAssertTrue(p.cuerpo.contains("<u:Created>2026-10-21T18:30:00.000Z</u:Created>"))
    }

    func testSolicitar() async throws {
        SATFalso.respuestas[solicitaEmitidos] = (200, Self.solicitudResp(5000, "4e80345d-917f-40bb-a98f-4a73939343c5", "Solicitud Aceptada"))
        let id = try await cliente().solicitar(.emitidos, .mes(2026, 9), .cfdi)
        XCTAssertEqual(id, "4e80345d-917f-40bb-a98f-4a73939343c5")
        let p = try XCTUnwrap(SATFalso.peticiones.last)
        XCTAssertEqual(p.url.absoluteString, "https://cfdidescargamasivasolicitud.clouda.sat.gob.mx/SolicitaDescargaService.svc")
        XCTAssertEqual(p.headers["SOAPAction"], "\"\(solicitaEmitidos)\"")
        XCTAssertEqual(p.headers["Authorization"], "WRAP access_token=\"TOKEN-1\"")
        XCTAssertEqual(p.headers["Accept"], "text/xml")
        XCTAssertEqual(p.headers["Cache-Control"], "no-cache")
        XCTAssertTrue(p.cuerpo.contains("<des:SolicitaDescargaEmitidos>"))
    }

    func testSolicitarRechazada() async throws {
        let resp = Self.solicitudResp(5002, "", "Se agotó las solicitudes de por vida")
            .replacingOccurrences(of: "Emitidos", with: "Recibidos")
        SATFalso.respuestas[solicitaRecibidos] = (200, resp)
        do {
            _ = try await cliente().solicitar(.recibidos, .mes(2026, 9), .cfdi)
            XCTFail("debió fallar")
        } catch SATError.codigo(let c, let m) {
            XCTAssertEqual(c, 5002)
            XCTAssertEqual(m, "Se agotó las solicitudes de por vida")
        }
    }

    func testVerificarTerminada() async throws {
        SATFalso.respuestas[verifica] = (200, """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema"><VerificaSolicitudDescargaResponse xmlns="http://DescargaMasivaTerceros.sat.gob.mx"><VerificaSolicitudDescargaResult CodEstatus="5000" EstadoSolicitud="3" CodigoEstadoSolicitud="5000" NumeroCFDIs="12" Mensaje="Solicitud Aceptada"><IdsPaquetes>4E80345D-917F-40BB-A98F-4A73939343C5_01</IdsPaquetes><IdsPaquetes>4E80345D-917F-40BB-A98F-4A73939343C5_02</IdsPaquetes></VerificaSolicitudDescargaResult></VerificaSolicitudDescargaResponse></s:Body></s:Envelope>
        """)
        let v = try await cliente().verificar("4e80345d-917f-40bb-a98f-4a73939343c5")
        XCTAssertEqual(v.estado, .terminada)
        XCTAssertEqual(v.codigoEstatus, 5000)
        XCTAssertEqual(v.codigoEstadoSolicitud, 5000)
        XCTAssertEqual(v.numeroCFDIs, 12)
        XCTAssertEqual(v.mensaje, "Solicitud Aceptada")
        XCTAssertEqual(v.paquetes, ["4E80345D-917F-40BB-A98F-4A73939343C5_01", "4E80345D-917F-40BB-A98F-4A73939343C5_02"])
        let p = try XCTUnwrap(SATFalso.peticiones.last)
        XCTAssertEqual(p.url.absoluteString, "https://cfdidescargamasivasolicitud.clouda.sat.gob.mx/VerificaSolicitudDescargaService.svc")
        XCTAssertEqual(p.headers["Authorization"], "WRAP access_token=\"TOKEN-1\"")
    }

    static func descargaResp(_ cod: Int, _ paquete: String) -> String {
        """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Header><h:respuesta CodEstatus="\(cod)" Mensaje="Solicitud Aceptada" xmlns:h="http://DescargaMasivaTerceros.sat.gob.mx" xmlns="http://DescargaMasivaTerceros.sat.gob.mx" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema"/></s:Header><s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema"><RespuestaDescargaMasivaTercerosSalida xmlns="http://DescargaMasivaTerceros.sat.gob.mx"><Paquete>\(paquete)</Paquete></RespuestaDescargaMasivaTercerosSalida></s:Body></s:Envelope>
        """
    }

    func testDescargar() async throws {
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        SATFalso.respuestas[descarga] = (200, Self.descargaResp(5000, zip.base64EncodedString()))
        let datos = try await cliente().descargar(paquete: "P_01")
        XCTAssertEqual(datos, zip)
        let p = try XCTUnwrap(SATFalso.peticiones.last)
        XCTAssertEqual(p.url.absoluteString, "https://cfdidescargamasiva.clouda.sat.gob.mx/DescargaMasivaService.svc")
        XCTAssertEqual(p.headers["SOAPAction"], "\"\(descarga)\"")
        XCTAssertTrue(p.cuerpo.contains("IdPaquete=\"P_01\""))
        // La bitácora no guarda el paquete, solo su tamaño.
        let e = try XCTUnwrap(entradas.last)
        XCTAssertEqual(e.operacion, "descarga")
        XCTAssertTrue(e.respuesta.contains("<Paquete>…(20 bytes base64)</Paquete>"))
    }

    func testDescargarCodigo() async throws {
        SATFalso.respuestas[descarga] = (200, Self.descargaResp(5008, ""))
        do {
            _ = try await cliente().descargar(paquete: "P_01")
            XCTFail("debió fallar")
        } catch SATError.codigo(let c, _) {
            XCTAssertEqual(c, 5008)
        }
    }

    func testFaultSOAP() async throws {
        SATFalso.respuestas[verifica] = (500, """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultcode xmlns:a="http://schemas.microsoft.com/ws/2005/05/addressing/none">a:ActionNotSupported</faultcode><faultstring xml:lang="es-MX">El token no es válido.</faultstring></s:Fault></s:Body></s:Envelope>
        """)
        do {
            _ = try await cliente().verificar("x")
            XCTFail("debió fallar")
        } catch SATError.fault(let m) {
            XCTAssertEqual(m, "El token no es válido.")
        }
    }

    func testHTTPSinFault() async throws {
        SATFalso.respuestas[verifica] = (503, "Service Unavailable")
        do {
            _ = try await cliente().verificar("x")
            XCTFail("debió fallar")
        } catch SATError.http(let c, let cuerpo) {
            XCTAssertEqual(c, 503)
            XCTAssertEqual(cuerpo, "Service Unavailable")
        }
    }

    func testBitacoraTapada() async throws {
        SATFalso.respuestas[solicitaEmitidos] = (200, Self.solicitudResp(5000, "abc", "ok"))
        _ = try await cliente().solicitar(.emitidos, .mes(2026, 9), .cfdi)
        XCTAssertEqual(entradas.map(\.operacion), ["autenticacion", "solicitud"])
        XCTAssertEqual(entradas[0].estadoHTTP, 200)
        let cert = try fixture("EKU9003173C9.cer").base64EncodedString()
        for e in entradas {
            XCTAssertFalse(e.peticion.contains(cert))
            XCTAssertFalse(e.respuesta.contains("TOKEN-1"))
            XCTAssertFalse(e.peticion.contains("TOKEN-1"))
        }
        XCTAssertTrue(entradas[0].peticion.contains("<o:BinarySecurityToken u:Id="))
        XCTAssertTrue(entradas[0].peticion.contains(">…(tapado)</o:BinarySecurityToken>"))
        XCTAssertTrue(entradas[0].peticion.contains("<SignatureValue>…(tapado)</SignatureValue>"))
        XCTAssertTrue(entradas[0].respuesta.contains("<AutenticaResult>…(tapado)</AutenticaResult>"))
        XCTAssertTrue(entradas[1].peticion.contains("<X509Certificate>…(tapado)</X509Certificate>"))
        XCTAssertTrue(entradas[1].peticion.contains("<DigestValue>"))   // lo demás queda
    }

    func testTapar() {
        XCTAssertEqual(DescargaMasiva.tapar("Authorization: WRAP access_token=\"eyJhbGciOi\""),
                       "Authorization: WRAP access_token=\"…(tapado)\"")
        XCTAssertEqual(DescargaMasiva.tapar("<a:Paquete x=\"1\">QUJD</a:Paquete><ds:SignatureValue>xyz</ds:SignatureValue>"),
                       "<a:Paquete x=\"1\">…(4 bytes base64)</a:Paquete><ds:SignatureValue>…(tapado)</ds:SignatureValue>")
        XCTAssertEqual(DescargaMasiva.tapar("<Otra>nada</Otra>"), "<Otra>nada</Otra>")
    }

    func testMensajes() {
        XCTAssertEqual(DescargaMasiva.mensaje(codigo: 305), "Certificado inválido.")
        XCTAssertTrue(DescargaMasiva.mensaje(codigo: 5002).hasPrefix("Se agotaron"))
        XCTAssertEqual(DescargaMasiva.mensaje(codigo: 9999), "El SAT respondió con el código 9999.")
    }
}
