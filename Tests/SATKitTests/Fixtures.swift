import XCTest
@testable import SATKit

// La e.firma de pruebas pública del SAT (EKU9003173C9, de phpcfdi), para todas las pruebas.
extension XCTestCase {
    func fixture(_ nombre: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/fiel/\(nombre)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    func efirma() throws -> EFirma {
        let pw = String(decoding: try fixture("EKU9003173C9-password.txt"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try EFirma(cer: fixture("EKU9003173C9.cer"), key: fixture("EKU9003173C9.key"), password: pw)
    }
}
