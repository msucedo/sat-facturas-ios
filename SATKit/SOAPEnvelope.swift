// Sobres SOAP del webservice de Descarga Masiva v1.5.
//
// Firmamos con XML-DSig, que firma la forma *canónica* del XML (exc-c14n): sin
// espacios entre etiquetas, con los atributos en orden, con las etiquetas vacías
// abiertas y cerradas, y con cada xmlns declarado donde se usa por primera vez.
// En vez de un serializador XML, escribimos las piezas firmadas ya en esa forma.
// Así el texto que va en el sobre es el mismo que firmamos, byte por byte.
//
// Autenticación (WS-Security):
//   1. u:Timestamp (Id "_0") con Created = ahora y Expires = ahora + 5 min.
//   2. DigestValue = SHA1 del Timestamp canónico.
//   3. SignedInfo apunta a "#_0" con ese digest; SignatureValue = RSA-SHA1 del SignedInfo.
//   4. BinarySecurityToken con el .cer en base64; KeyInfo lo referencia por su Id.

import Foundation
import CryptoKit

public enum SOAPEnvelope {
    static let nsU = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
    static let nsO = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
    static let nsDS = "http://www.w3.org/2000/09/xmldsig#"
    static let x509v3 = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-x509-token-profile-1.0#X509v3"
    static let base64Binary = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary"
    static let excC14N = "http://www.w3.org/2001/10/xml-exc-c14n#"
    static let rsaSHA1 = "http://www.w3.org/2000/09/xmldsig#rsa-sha1"
    static let sha1 = "http://www.w3.org/2000/09/xmldsig#sha1"

    /// Cuánto vive la petición de autenticación (y el token que devuelve el SAT).
    public static let vigenciaToken: TimeInterval = 300

    /// Sobre para `IAutenticacion/Autentica`. `creado` y `uuid` se pueden fijar en pruebas.
    public static func autenticacion(efirma: EFirma, creado: Date = Date(), uuid: UUID = UUID()) throws -> String {
        let timestamp = timestampCanonico(creado: creado)
        let signedInfo = signedInfoCanonico(uri: "#_0", digest: digestSHA1(timestamp))
        let firma = try efirma.firmar(Data(signedInfo.utf8), .sha1).base64EncodedString()
        let tokenId = "uuid-\(uuid.uuidString.lowercased())-4"
        let cert = efirma.certificado.der.base64EncodedString()

        return """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" xmlns:u="\(nsU)">\
        <s:Header>\
        <o:Security xmlns:o="\(nsO)" s:mustUnderstand="1">\
        \(timestamp)\
        <o:BinarySecurityToken u:Id="\(tokenId)" ValueType="\(x509v3)" EncodingType="\(base64Binary)">\(cert)</o:BinarySecurityToken>\
        <Signature xmlns="\(nsDS)">\
        \(signedInfo)\
        <SignatureValue>\(firma)</SignatureValue>\
        <KeyInfo><o:SecurityTokenReference><o:Reference URI="#\(tokenId)" ValueType="\(x509v3)"/></o:SecurityTokenReference></KeyInfo>\
        </Signature>\
        </o:Security>\
        </s:Header>\
        <s:Body><Autentica xmlns="http://DescargaMasivaTerceros.gob.mx"/></s:Body>\
        </s:Envelope>
        """
    }

    // MARK: solicitud, verificación y descarga (firma envuelta)
    //
    // La firma va dentro del elemento que firma (des:solicitud o des:peticionDescarga):
    //   1. Escribimos el elemento canónico sin firma (exc-c14n): xmlns:des en él mismo,
    //      atributos en orden alfabético y etiquetas abiertas y cerradas.
    //   2. DigestValue = SHA1 de ese texto. Reference URI="" con los transforms
    //      enveloped-signature (quita la firma) y exc-c14n (lo que calculamos).
    //   3. Metemos la Signature justo antes de la etiqueta de cierre.
    // El token va en el header HTTP Authorization, así que s:Header queda vacío.

    static let nsDes = "http://DescargaMasivaTerceros.sat.gob.mx"
    static let envelopedSignature = "http://www.w3.org/2000/09/xmldsig#enveloped-signature"

    /// Sobre para `SolicitaDescargaEmitidos` / `SolicitaDescargaRecibidos` (v1.5).
    public static func solicitud(efirma: EFirma, tipo: TipoDescarga, periodo: Periodo,
                                 solicitud: TipoSolicitud) throws -> String {
        let rfc = efirma.certificado.rfc
        // Los recibidos en XML solo pueden ser vigentes; la Metadata trae todos.
        let estado = tipo == .recibidos && solicitud == .cfdi ? "Vigente" : "Todos"
        var attrs = [("EstadoComprobante", estado),
                     ("FechaFinal", fechaMexico(periodo.fin)),
                     ("FechaInicial", fechaMexico(periodo.inicio)),
                     ("TipoSolicitud", solicitud.rawValue)]
        var hijos = ""
        if tipo == .emitidos {
            attrs.append(("RfcEmisor", rfc))
        } else {
            attrs.append(("RfcReceptor", rfc))
            hijos = "<des:RfcReceptores><des:RfcReceptor>\(c14nTexto(rfc))</des:RfcReceptor></des:RfcReceptores>"
        }
        let firmado = try elementoFirmado(efirma: efirma, nombre: "des:solicitud", atributos: attrs, hijos: hijos)
        return sobreDes("<des:SolicitaDescarga\(tipo.rawValue)>\(firmado)</des:SolicitaDescarga\(tipo.rawValue)>")
    }

    /// Sobre para `VerificaSolicitudDescarga`.
    public static func verificacion(efirma: EFirma, idSolicitud: String) throws -> String {
        let firmado = try elementoFirmado(efirma: efirma, nombre: "des:solicitud", atributos: [
            ("IdSolicitud", idSolicitud), ("RfcSolicitante", efirma.certificado.rfc)])
        return sobreDes("<des:VerificaSolicitudDescarga>\(firmado)</des:VerificaSolicitudDescarga>")
    }

    /// Sobre para `Descargar` (PeticionDescargaMasivaTercerosEntrada).
    public static func descarga(efirma: EFirma, idPaquete: String) throws -> String {
        let firmado = try elementoFirmado(efirma: efirma, nombre: "des:peticionDescarga", atributos: [
            ("IdPaquete", idPaquete), ("RfcSolicitante", efirma.certificado.rfc)])
        return sobreDes("<des:PeticionDescargaMasivaTercerosEntrada>\(firmado)</des:PeticionDescargaMasivaTercerosEntrada>")
    }

    static func sobreDes(_ cuerpo: String) -> String {
        "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:des=\"\(nsDes)\">"
            + "<s:Header></s:Header><s:Body>\(cuerpo)</s:Body></s:Envelope>"
    }

    /// El elemento canónico (sin firma) de una operación con firma envuelta.
    static func elementoCanonico(nombre: String, atributos: [(String, String)], hijos: String = "") -> String {
        // Atributos sin prefijo: orden por nombre local (código Unicode, como pide c14n).
        let a = atributos.sorted { $0.0.unicodeScalars.lexicographicallyPrecedes($1.0.unicodeScalars) }
            .map { " \($0.0)=\"\(c14nAtributo($0.1))\"" }.joined()
        return "<\(nombre) xmlns:des=\"\(nsDes)\"\(a)>\(hijos)</\(nombre)>"
    }

    /// El mismo elemento con la Signature adentro, al final.
    static func elementoFirmado(efirma: EFirma, nombre: String, atributos: [(String, String)],
                                hijos: String = "") throws -> String {
        let canonico = elementoCanonico(nombre: nombre, atributos: atributos, hijos: hijos)
        let signedInfo = signedInfoCanonico(uri: "", digest: digestSHA1(canonico),
                                            transforms: [envelopedSignature, excC14N])
        let firma = try efirma.firmar(Data(signedInfo.utf8), .sha1).base64EncodedString()
        let c = efirma.certificado
        let signature = "<Signature xmlns=\"\(nsDS)\">\(signedInfo)"
            + "<SignatureValue>\(firma)</SignatureValue>"
            + "<KeyInfo><X509Data><X509IssuerSerial>"
            + "<X509IssuerName>\(xmlEscape(c.emisor))</X509IssuerName>"
            + "<X509SerialNumber>\(c.serialDecimal)</X509SerialNumber>"
            + "</X509IssuerSerial>"
            + "<X509Certificate>\(c.der.base64EncodedString())</X509Certificate>"
            + "</X509Data></KeyInfo></Signature>"
        let cierre = "</\(nombre)>"
        return String(canonico.dropLast(cierre.count)) + signature + cierre
    }

    // 2026-10-01T00:00:00, hora de México (así interpreta el SAT las fechas).
    static func fechaMexico(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Periodo.zona
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: d)
    }

    // Escapes de c14n: en atributos & < " y tab/LF/CR; en texto & < > y CR.
    static func c14nAtributo(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case "\"": out += "&quot;"
            case "\t": out += "&#x9;"
            case "\n": out += "&#xA;"
            case "\r": out += "&#xD;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    static func c14nTexto(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\r": out += "&#xD;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    // MARK: piezas canónicas

    // El xmlns:u va en el propio Timestamp: en exc-c14n el prefijo se declara en el
    // primer elemento que lo usa. En el sobre queda repetido (ya está en s:Envelope),
    // y eso es XML válido.
    static func timestampCanonico(creado: Date) -> String {
        let expira = creado.addingTimeInterval(vigenciaToken)
        return "<u:Timestamp xmlns:u=\"\(nsU)\" u:Id=\"_0\">"
            + "<u:Created>\(fecha(creado))</u:Created>"
            + "<u:Expires>\(fecha(expira))</u:Expires>"
            + "</u:Timestamp>"
    }

    static func signedInfoCanonico(uri: String, digest: String, transforms: [String] = [excC14N]) -> String {
        "<SignedInfo xmlns=\"\(nsDS)\">"
            + "<CanonicalizationMethod Algorithm=\"\(excC14N)\"></CanonicalizationMethod>"
            + "<SignatureMethod Algorithm=\"\(rsaSHA1)\"></SignatureMethod>"
            + "<Reference URI=\"\(c14nAtributo(uri))\">"
            + "<Transforms>" + transforms.map { "<Transform Algorithm=\"\($0)\"></Transform>" }.joined() + "</Transforms>"
            + "<DigestMethod Algorithm=\"\(sha1)\"></DigestMethod>"
            + "<DigestValue>\(digest)</DigestValue>"
            + "</Reference>"
            + "</SignedInfo>"
    }

    static func digestSHA1(_ texto: String) -> String {
        Data(Insecure.SHA1.hash(data: Data(texto.utf8))).base64EncodedString()
    }

    // 2026-10-21T18:30:00.000Z, siempre en UTC.
    static func fecha(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// Escapa texto para ponerlo dentro de un atributo o de un elemento.
    public static func xmlEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }
}
