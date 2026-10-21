import XCTest
@testable import SATKit

// Usa la e.firma de pruebas pública del SAT (EKU9003173C9, de phpcfdi).
final class EFirmaTests: XCTestCase {
    func testCertificado() throws {
        let c = try efirma().certificado
        XCTAssertEqual(c.rfc, "EKU9003173C9")
        XCTAssertEqual(c.nombre, "ESCUELA KEMPER URGATE SA DE CV")
        XCTAssertEqual(c.noCertificado, "30001000000500003415")
        XCTAssertEqual(c.validoHasta, Date(timeIntervalSince1970: 1_810_528_634)) // 2027-05-17 04:37:14Z
        XCTAssertTrue(c.emisor.hasPrefix("CN="))
    }

    func testPasswordIncorrecta() throws {
        XCTAssertThrowsError(try LlavePrivada(der: fixture("EKU9003173C9.key"), password: "nope")) { e in
            XCTAssertEqual((e as? EFirmaError)?.description, EFirmaError.passwordIncorrecta.description)
        }
    }

    func testFirmaSeVerificaConElCertificado() throws {
        let f = try efirma()
        let datos = Data("hola SAT".utf8)
        for (alg, sec) in [(LlavePrivada.Algoritmo.sha1, SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA1),
                           (.sha256, .rsaSignatureMessagePKCS1v15SHA256)] {
            let firma = try f.firmar(datos, alg)
            XCTAssertEqual(firma.count, 256)   // RSA 2048
            XCTAssertTrue(SecKeyVerifySignature(try XCTUnwrap(f.certificado.llavePublica), sec,
                                                datos as CFData, firma as CFData, nil))
        }
    }

    // RSA PKCS#1 v1.5 es determinista: debe dar exactamente los mismos bytes que
    // `openssl dgst -sha1 -sign` con la misma llave.
    func testFirmaIgualQueOpenSSL() throws {
        let esperada = "gk16cvUwIF0E5EnR1nYu/ZDmqB6/zvvzh3vVIHpyWA37HrTIdXcrQqPY1uVMTg70gartaRzndA3EB9rXt7SISkQUHOHXaRgvGh9x2eDfj53mdJfqi9MH0sK1KX5JbBQqawQkc1dTFjQasjLp6gHW+K4o2xPtj7sbB+mBBOiUeyokv5KDVm/yWN74V/37jsR3oiUBiLsDEswKT0H1O90a1rh7sNggJ24OxnWtHWw9JdDOa4ooWSJggK7IeO5EffGS/2eeyA0vP/SKo2ZGGrjOvZ5nAruqjRE+R5R/QoHL6RvQmvJFWfJ8EmHSk7D9jzomOeuNf8PHCt0ZjPfd5qceOw=="
        XCTAssertEqual(try efirma().firmar(Data("hola SAT".utf8)).base64EncodedString(), esperada)
    }
}
