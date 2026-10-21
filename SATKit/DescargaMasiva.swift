// Cliente del webservice de Descarga Masiva v1.5 del SAT.
//
//   autenticar → token (vive 5 min; lo reusamos mientras siga vigente)
//   solicitar  → IdSolicitud
//   verificar  → estado y, cuando está Terminada, los IdsPaquetes
//   descargar  → el ZIP de un paquete
//
// Cada petición se anota en `bitacora` con la firma, el certificado y el token tapados.

import Foundation

public final class DescargaMasiva {
    enum Endpoint {
        static let autenticacion = URL(string: "https://cfdidescargamasivasolicitud.clouda.sat.gob.mx/Autenticacion/Autenticacion.svc")!
        static let solicitud = URL(string: "https://cfdidescargamasivasolicitud.clouda.sat.gob.mx/SolicitaDescargaService.svc")!
        static let verificacion = URL(string: "https://cfdidescargamasivasolicitud.clouda.sat.gob.mx/VerificaSolicitudDescargaService.svc")!
        static let descarga = URL(string: "https://cfdidescargamasiva.clouda.sat.gob.mx/DescargaMasivaService.svc")!
    }

    enum Accion {
        static let autentica = "http://DescargaMasivaTerceros.gob.mx/IAutenticacion/Autentica"
        static func solicita(_ t: TipoDescarga) -> String {
            "http://DescargaMasivaTerceros.sat.gob.mx/ISolicitaDescargaService/SolicitaDescarga\(t.rawValue)"
        }
        static let verifica = "http://DescargaMasivaTerceros.sat.gob.mx/IVerificaSolicitudDescargaService/VerificaSolicitudDescarga"
        static let descarga = "http://DescargaMasivaTerceros.sat.gob.mx/IDescargaMasivaTercerosService/Descargar"
    }

    let efirma: EFirma
    let session: URLSession
    let reloj: () -> Date
    var token: Token?

    public var bitacora: ((EntradaBitacora) -> Void)?

    public init(efirma: EFirma, session: URLSession = .shared, reloj: @escaping () -> Date = Date.init) {
        self.efirma = efirma; self.session = session; self.reloj = reloj
    }

    // MARK: operaciones

    public func autenticar() async throws -> Token {
        if let t = token, t.vigente(reloj()) { return t }
        let ahora = reloj()
        let sobre = try SOAPEnvelope.autenticacion(efirma: efirma, creado: ahora)
        let xml = try await enviar("autenticacion", Endpoint.autenticacion, Accion.autentica, sobre, token: nil)
        guard let valor = xml.buscar("AutenticaResult")?.texto, !valor.isEmpty else {
            throw SATError.respuestaInvalida("sin AutenticaResult")
        }
        let t = Token(valor: valor, expira: ahora.addingTimeInterval(SOAPEnvelope.vigenciaToken))
        token = t
        return t
    }

    /// Devuelve el IdSolicitud.
    public func solicitar(_ tipo: TipoDescarga, _ periodo: Periodo, _ solicitud: TipoSolicitud) async throws -> String {
        let t = try await autenticar()
        let sobre = try SOAPEnvelope.solicitud(efirma: efirma, tipo: tipo, periodo: periodo, solicitud: solicitud)
        let xml = try await enviar("solicitud", Endpoint.solicitud, Accion.solicita(tipo), sobre, token: t)
        guard let r = xml.buscar("SolicitaDescarga\(tipo.rawValue)Result") else {
            throw SATError.respuestaInvalida("sin SolicitaDescarga\(tipo.rawValue)Result")
        }
        try Self.revisar(r)
        guard let id = r.attrs["IdSolicitud"], !id.isEmpty else { throw SATError.respuestaInvalida("sin IdSolicitud") }
        return id
    }

    public func verificar(_ id: String) async throws -> Verificacion {
        let t = try await autenticar()
        let sobre = try SOAPEnvelope.verificacion(efirma: efirma, idSolicitud: id)
        let xml = try await enviar("verificacion", Endpoint.verificacion, Accion.verifica, sobre, token: t)
        guard let r = xml.buscar("VerificaSolicitudDescargaResult") else {
            throw SATError.respuestaInvalida("sin VerificaSolicitudDescargaResult")
        }
        let cod = try Self.revisar(r)
        guard let n = r.attrs["EstadoSolicitud"].flatMap(Int.init), let estado = EstadoSolicitud(rawValue: n) else {
            throw SATError.respuestaInvalida("EstadoSolicitud \(r.attrs["EstadoSolicitud"] ?? "ausente")")
        }
        return Verificacion(estado: estado, codigoEstatus: cod,
                            codigoEstadoSolicitud: r.attrs["CodigoEstadoSolicitud"].flatMap(Int.init) ?? 0,
                            numeroCFDIs: r.attrs["NumeroCFDIs"].flatMap(Int.init) ?? 0,
                            mensaje: r.attrs["Mensaje"] ?? "",
                            paquetes: r.todos("IdsPaquetes").map(\.texto).filter { !$0.isEmpty })
    }

    /// El ZIP del paquete, ya decodificado.
    public func descargar(paquete: String) async throws -> Data {
        let t = try await autenticar()
        let sobre = try SOAPEnvelope.descarga(efirma: efirma, idPaquete: paquete)
        let xml = try await enviar("descarga", Endpoint.descarga, Accion.descarga, sobre, token: t)
        guard let r = xml.buscar("respuesta") else { throw SATError.respuestaInvalida("sin h:respuesta") }
        try Self.revisar(r)
        guard let b64 = xml.buscar("Paquete")?.texto,
              let zip = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), !zip.isEmpty else {
            throw SATError.respuestaInvalida("Paquete vacío o mal codificado")
        }
        return zip
    }

    // CodEstatus 5000 = bien; si no, el error con su mensaje.
    @discardableResult
    static func revisar(_ r: NodoXML) throws -> Int {
        guard let cod = r.attrs["CodEstatus"].flatMap(Int.init) else { throw SATError.respuestaInvalida("sin CodEstatus") }
        guard cod == 5000 else {
            let m = r.attrs["Mensaje"].flatMap { $0.isEmpty ? nil : $0 } ?? mensaje(codigo: cod)
            throw SATError.codigo(cod, m)
        }
        return cod
    }

    // MARK: HTTP

    func enviar(_ operacion: String, _ url: URL, _ accion: String, _ sobre: String, token: Token?) async throws -> NodoXML {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 65)
        req.httpMethod = "POST"
        req.httpBody = Data(sobre.utf8)
        req.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("text/xml", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("\"\(accion)\"", forHTTPHeaderField: "SOAPAction")
        if let token { req.setValue("WRAP access_token=\"\(token.valor)\"", forHTTPHeaderField: "Authorization") }

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            bitacora?(EntradaBitacora(fecha: reloj(), operacion: operacion, url: url.absoluteString, estadoHTTP: nil,
                                      peticion: Self.tapar(sobre), respuesta: "error de red: \(error.localizedDescription)"))
            throw error
        }
        let cuerpo = String(decoding: data, as: UTF8.self)
        let estado = (resp as? HTTPURLResponse)?.statusCode ?? 0
        bitacora?(EntradaBitacora(fecha: reloj(), operacion: operacion, url: url.absoluteString, estadoHTTP: estado,
                                  peticion: Self.tapar(sobre), respuesta: Self.tapar(cuerpo)))

        let xml = NodoXML.parse(data)
        if let fault = xml?.buscar("Fault") {
            let m = fault.buscar("faultstring")?.texto ?? fault.buscar("Text")?.texto ?? "SOAP fault"
            throw SATError.fault(m)
        }
        guard (200..<300).contains(estado) else { throw SATError.http(estado, cuerpo) }
        guard let xml else { throw SATError.respuestaInvalida("el cuerpo no es XML") }
        return xml
    }

    // MARK: bitácora

    static let tapado = "…(tapado)"
    static let etiquetasTapadas = ["BinarySecurityToken", "SignatureValue", "X509Certificate", "AutenticaResult"]

    /// Quita del texto lo que no debe guardarse: certificado, firma y token.
    /// El contenido del Paquete se cambia por su tamaño.
    public static func tapar(_ texto: String) -> String {
        var s = texto
        for e in etiquetasTapadas {
            s = reemplazar(s, patron: "(<(?:[A-Za-z_][\\w.-]*:)?\(e)(?:\\s[^>]*)?>)([^<]*)(</(?:[A-Za-z_][\\w.-]*:)?\(e)>)") { _ in tapado }
        }
        s = reemplazar(s, patron: "(<(?:[A-Za-z_][\\w.-]*:)?Paquete(?:\\s[^>]*)?>)([^<]*)(</(?:[A-Za-z_][\\w.-]*:)?Paquete>)") {
            "…(\($0.utf8.count) bytes base64)"
        }
        s = reemplazar(s, patron: "(access_token=(?:\"|&quot;))([^\"&]*)((?:\"|&quot;))") { _ in tapado }
        return s
    }

    // Reemplaza el grupo 2 de cada coincidencia; los grupos 1 y 3 se quedan.
    static func reemplazar(_ s: String, patron: String, _ f: (String) -> String) -> String {
        let re = try! NSRegularExpression(pattern: patron)
        let ns = s as NSString
        var out = "", ultimo = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: ultimo, length: m.range.location - ultimo))
            out += ns.substring(with: m.range(at: 1)) + f(ns.substring(with: m.range(at: 2))) + ns.substring(with: m.range(at: 3))
            ultimo = m.range.location + m.range.length
        }
        return out + ns.substring(from: ultimo)
    }

    // MARK: mensajes

    /// Texto en español para los códigos del SAT (CodEstatus y CodigoEstadoSolicitud).
    public static func mensaje(codigo: Int) -> String {
        switch codigo {
        case 300: return "Usuario no válido."
        case 301: return "XML mal formado."
        case 302: return "Sello mal formado."
        case 303: return "El sello no corresponde con el RFC solicitante."
        case 304: return "Certificado revocado o caducado."
        case 305: return "Certificado inválido."
        case 5000: return "Solicitud recibida con éxito."
        case 5001: return "Tercero no autorizado."
        case 5002: return "Se agotaron las solicitudes de por vida para esta consulta. Cambia el rango de fechas, aunque sea un segundo."
        case 5003: return "La solicitud supera el tope de 200,000 CFDI. Pide un rango más corto."
        case 5004: return "No se encontraron CFDI para esta solicitud."
        case 5005: return "Ya existe una solicitud idéntica."
        case 5006: return "Error interno del SAT. Intenta más tarde."
        case 5007: return "El paquete ya no existe: los paquetes duran 72 horas. Vuelve a solicitar."
        case 5008: return "Ya se descargó este paquete el máximo de veces permitido (2)."
        case 5011: return "Se alcanzó el límite de descargas por día."
        default: return "El SAT respondió con el código \(codigo)."
        }
    }
}

// MARK: lector de XML

/// Árbol mínimo de la respuesta. Los nombres van sin prefijo: así no importa
/// qué namespaces use el SAT.
final class NodoXML {
    let nombre: String
    var attrs: [String: String] = [:]
    var texto = ""
    var hijos: [NodoXML] = []
    init(_ nombre: String) { self.nombre = nombre }

    func buscar(_ n: String) -> NodoXML? {
        if nombre == n { return self }
        for h in hijos { if let r = h.buscar(n) { return r } }
        return nil
    }

    func todos(_ n: String) -> [NodoXML] {
        (nombre == n ? [self] : []) + hijos.flatMap { $0.todos(n) }
    }

    static func parse(_ data: Data) -> NodoXML? {
        let d = Lector()
        let p = XMLParser(data: data)
        p.delegate = d
        guard p.parse(), let raiz = d.raiz else { return nil }
        return raiz
    }

    static func local(_ n: String) -> String { n.split(separator: ":").last.map(String.init) ?? n }

    final class Lector: NSObject, XMLParserDelegate {
        var raiz: NodoXML?
        var pila: [NodoXML] = []

        func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            let n = NodoXML(NodoXML.local(e))
            for (k, v) in attributes where !k.hasPrefix("xmlns") { n.attrs[NodoXML.local(k)] = v }
            if let padre = pila.last { padre.hijos.append(n) } else { raiz = n }
            pila.append(n)
        }
        func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if let n = pila.popLast() { n.texto = n.texto.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) { pila.last?.texto += s }
    }
}
