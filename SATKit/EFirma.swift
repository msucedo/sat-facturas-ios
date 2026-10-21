// La e.firma (antes FIEL): un certificado .cer y una llave privada .key.
//
// - El .cer es un X.509 en DER. De ahí salen el RFC (atributo
//   x500UniqueIdentifier, OID 2.5.4.45), el nombre, la vigencia y el "número de
//   certificado" que usa el SAT (el número de serie leído como texto ASCII).
// - El .key es un PKCS#8 cifrado con PBES2: la contraseña pasa por PBKDF2
//   (HMAC-SHA1, sal y 2048 vueltas que vienen en el archivo) para sacar una llave
//   3DES, y con ella se descifra la llave RSA. CommonCrypto hace ambas cosas.
//
// Con eso firmamos los sobres SOAP del webservice de Descarga Masiva.

import Foundation
import Security
import CommonCrypto

public struct Certificado {
    public let der: Data
    public let rfc: String
    public let nombre: String
    public let noCertificado: String
    public let validoDesde: Date
    public let validoHasta: Date
    public let emisor: String          // emisor del certificado, tal como va en X509IssuerName
    public let serialDecimal: String   // número de serie en decimal (X509SerialNumber)
    let secCertificate: SecCertificate

    public init(der: Data) throws {
        guard let sec = SecCertificateCreateWithData(nil, der as CFData) else {
            throw EFirmaError.certificadoInvalido
        }
        self.der = der
        self.secCertificate = sec

        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
        let tbs = try DERNode.parse(der).child(0)
        var fields = try tbs.children()
        if fields.first?.tag == 0xA0 { fields.removeFirst() }   // [0] version
        guard fields.count >= 6 else { throw EFirmaError.certificadoInvalido }
        let serial = fields[0], issuer = fields[2], validity = fields[3], subject = fields[4]

        // El SAT guarda el número de certificado como dígitos ASCII dentro del serial.
        noCertificado = String(decoding: serial.content.drop { $0 == 0 }, as: UTF8.self)
        serialDecimal = Certificado.decimal(serial.content)

        guard let desde = try validity.child(0).dateValue,
              let hasta = try validity.child(1).dateValue else { throw EFirmaError.certificadoInvalido }
        validoDesde = desde
        validoHasta = hasta

        let sujeto = try Certificado.atributos(subject)
        // Persona moral: "RFC_EMPRESA / RFC_REPRESENTANTE". Nos quedamos con el primero.
        guard let unico = sujeto.first(where: { $0.oid == "2.5.4.45" })?.valor else {
            throw EFirmaError.sinRFC
        }
        rfc = unico.components(separatedBy: "/").first!.trimmingCharacters(in: .whitespaces)
        nombre = sujeto.first(where: { $0.oid == "2.5.4.41" })?.valor
            ?? sujeto.first(where: { $0.oid == "2.5.4.3" })?.valor ?? ""
        emisor = try Certificado.nombreX500(issuer)
    }

    public var vigente: Bool {
        let ahora = Date()
        return validoDesde <= ahora && ahora <= validoHasta
    }

    var llavePublica: SecKey? { SecCertificateCopyKey(secCertificate) }

    // Name ::= SEQUENCE OF SET OF SEQUENCE { OID, valor }
    static func atributos(_ name: DERNode) throws -> [(oid: String, valor: String)] {
        var out: [(String, String)] = []
        for rdn in try name.children() {
            for atv in try rdn.children() {
                let par = try atv.children()
                if par.count == 2, let oid = par[0].oidString, let v = par[1].stringValue {
                    out.append((oid, v))
                }
            }
        }
        return out
    }

    // Formato "CN=...,O=..." en el orden del certificado (el que pide XML-DSig).
    static func nombreX500(_ name: DERNode) throws -> String {
        let cortos = ["2.5.4.3": "CN", "2.5.4.10": "O", "2.5.4.11": "OU", "2.5.4.6": "C",
                      "2.5.4.7": "L", "2.5.4.8": "ST", "2.5.4.9": "street", "2.5.4.17": "postalCode",
                      "2.5.4.45": "x500UniqueIdentifier", "2.5.4.5": "serialNumber",
                      "2.5.4.41": "name", "1.2.840.113549.1.9.1": "emailAddress",
                      "1.2.840.113549.1.9.2": "unstructuredName"]
        return try atributos(name)
            .map { "\(cortos[$0.oid] ?? $0.oid)=\($0.valor)" }
            .joined(separator: ",")
    }

    // Entero sin signo big-endian → texto decimal (el serial no cabe en 64 bits).
    static func decimal(_ bytes: Data) -> String {
        var digits: [UInt8] = [0]   // dígitos decimales, el menos significativo primero
        for b in bytes {
            var carry = Int(b)
            for i in digits.indices {
                let v = Int(digits[i]) * 256 + carry
                digits[i] = UInt8(v % 10)
                carry = v / 10
            }
            while carry > 0 { digits.append(UInt8(carry % 10)); carry /= 10 }
        }
        while digits.count > 1, digits.last == 0 { digits.removeLast() }
        return digits.reversed().map(String.init).joined()
    }
}

public struct LlavePrivada {
    let secKey: SecKey

    // `der` es el .key tal cual (PKCS#8 cifrado).
    public init(der: Data, password: String) throws {
        let pkcs8 = try LlavePrivada.descifrar(der, password: password)
        // PrivateKeyInfo ::= SEQUENCE { version, algorithm, OCTET STRING RSAPrivateKey }
        let info = try DERNode.parse(pkcs8)
        let rsa = try info.child(2)
        guard rsa.tag == DERNode.octetString else { throw EFirmaError.llaveInvalida }
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(rsa.content as CFData, attrs as CFDictionary, &error) else {
            throw EFirmaError.llaveInvalida
        }
        secKey = key
    }

    public enum Algoritmo { case sha1, sha256 }

    // Firma RSA PKCS#1 v1.5 sobre los datos (Security calcula el digest).
    public func firmar(_ datos: Data, _ alg: Algoritmo = .sha1) throws -> Data {
        let algoritmo: SecKeyAlgorithm = alg == .sha1
            ? .rsaSignatureMessagePKCS1v15SHA1 : .rsaSignatureMessagePKCS1v15SHA256
        var error: Unmanaged<CFError>?
        guard let firma = SecKeyCreateSignature(secKey, algoritmo, datos as CFData, &error) else {
            throw EFirmaError.firmaFallida
        }
        return firma as Data
    }

    // EncryptedPrivateKeyInfo ::= SEQUENCE {
    //   SEQUENCE { OID pbes2, SEQUENCE {
    //     SEQUENCE { OID pbkdf2, SEQUENCE { OCTET sal, INTEGER vueltas, [prf] } },
    //     SEQUENCE { OID des-ede3-cbc, OCTET iv } } },
    //   OCTET STRING datosCifrados }
    static func descifrar(_ der: Data, password: String) throws -> Data {
        let raiz = try DERNode.parse(der)
        let alg = try raiz.child(0)
        guard try alg.child(0).oidString == "1.2.840.113549.1.5.13" else {   // PBES2
            throw EFirmaError.formatoLlaveNoSoportado
        }
        let params = try alg.child(1)
        let kdf = try params.child(0), cifrado = try params.child(1)
        guard try kdf.child(0).oidString == "1.2.840.113549.1.5.12" else {   // PBKDF2
            throw EFirmaError.formatoLlaveNoSoportado
        }
        let kdfParams = try kdf.child(1).children()
        let sal = kdfParams[0].content
        guard let vueltas = kdfParams[1].intValue else { throw EFirmaError.llaveInvalida }
        // prf opcional; por omisión HMAC-SHA1. Algunas llaves traen HMAC-SHA256.
        var prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        if let ultimo = kdfParams.last, ultimo.tag == DERNode.sequence,
           try ultimo.child(0).oidString == "1.2.840.113549.2.9" {
            prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        }

        let (ccAlg, tamLlave, tamBloque): (CCAlgorithm, Int, Int)
        switch try cifrado.child(0).oidString {
        case "1.2.840.113549.3.7":       (ccAlg, tamLlave, tamBloque) = (CCAlgorithm(kCCAlgorithm3DES), kCCKeySize3DES, kCCBlockSize3DES)
        case "2.16.840.1.101.3.4.1.42":  (ccAlg, tamLlave, tamBloque) = (CCAlgorithm(kCCAlgorithmAES), kCCKeySizeAES256, kCCBlockSizeAES128)
        default: throw EFirmaError.formatoLlaveNoSoportado
        }
        let iv = try cifrado.child(1).content
        let datos = try raiz.child(1).content

        // 1) contraseña → llave simétrica
        var llave = Data(count: tamLlave)
        let pw = Array(password.utf8)
        let st = llave.withUnsafeMutableBytes { k in
            sal.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     password, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, sal.count,
                                     prf, UInt32(vueltas),
                                     k.bindMemory(to: UInt8.self).baseAddress, tamLlave)
            }
        }
        guard st == kCCSuccess else { throw EFirmaError.llaveInvalida }

        // 2) descifrar (CBC + PKCS#7). Con contraseña errónea casi siempre falla el
        //    relleno; si por suerte no, el DER resultante no se deja leer.
        var salida = Data(count: datos.count + tamBloque)
        var movidos = 0
        let capacidad = salida.count
        let r = salida.withUnsafeMutableBytes { o in
            datos.withUnsafeBytes { d in
                llave.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), ccAlg, CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, tamLlave, v.baseAddress,
                                d.baseAddress, datos.count, o.baseAddress, capacidad, &movidos)
                    }
                }
            }
        }
        guard r == kCCSuccess else { throw EFirmaError.passwordIncorrecta }
        salida.count = movidos
        guard (try? DERNode.parse(salida))?.tag == DERNode.sequence else { throw EFirmaError.passwordIncorrecta }
        return salida
    }
}

public struct EFirma {
    public let certificado: Certificado
    public let llave: LlavePrivada

    public init(cer: Data, key: Data, password: String) throws {
        certificado = try Certificado(der: cer)
        llave = try LlavePrivada(der: key, password: password)
        // Que la llave sea la pareja del certificado: firmamos algo y lo verificamos.
        let prueba = Data("pareja".utf8)
        let firma = try llave.firmar(prueba)
        guard let pub = certificado.llavePublica,
              SecKeyVerifySignature(pub, .rsaSignatureMessagePKCS1v15SHA1,
                                    prueba as CFData, firma as CFData, nil) else {
            throw EFirmaError.noSonPareja
        }
    }

    public func firmar(_ datos: Data, _ alg: LlavePrivada.Algoritmo = .sha1) throws -> Data {
        try llave.firmar(datos, alg)
    }
}

public enum EFirmaError: Error, CustomStringConvertible {
    case certificadoInvalido, sinRFC, llaveInvalida, formatoLlaveNoSoportado
    case passwordIncorrecta, noSonPareja, firmaFallida

    public var description: String {
        switch self {
        case .certificadoInvalido: return "El .cer no es un certificado válido."
        case .sinRFC: return "El certificado no trae RFC (¿es un CSD en vez de e.firma?)."
        case .llaveInvalida: return "El .key no es una llave válida."
        case .formatoLlaveNoSoportado: return "Formato de .key no soportado."
        case .passwordIncorrecta: return "La contraseña de la llave es incorrecta."
        case .noSonPareja: return "El .key no corresponde a ese .cer."
        case .firmaFallida: return "No se pudo firmar."
        }
    }
}
