// Tipos compartidos de SATKit: los usan el protocolo (DescargaMasiva), los
// lectores de datos (CFDIParser, MetadataParser) y la app.

import Foundation

// MARK: Descarga Masiva

public enum TipoDescarga: String, Codable, CaseIterable, Sendable {
    case emitidos = "Emitidos", recibidos = "Recibidos"
}

public enum TipoSolicitud: String, Codable, CaseIterable, Sendable {
    case cfdi = "CFDI", metadata = "Metadata"
}

/// Rango de fechas con hora, en la zona horaria de México (como las interpreta el SAT).
public struct Periodo: Codable, Hashable, Sendable {
    public var inicio: Date
    public var fin: Date
    public init(inicio: Date, fin: Date) { self.inicio = inicio; self.fin = fin }

    public static let zona = TimeZone(identifier: "America/Mexico_City")!

    /// Del día 1 a las 00:00:00 al último día a las 23:59:59.
    public static func mes(_ año: Int, _ mes: Int) -> Periodo {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zona
        let inicio = cal.date(from: DateComponents(year: año, month: mes, day: 1))!
        let siguiente = cal.date(byAdding: .month, value: 1, to: inicio)!
        return Periodo(inicio: inicio, fin: siguiente.addingTimeInterval(-1))
    }
}

public struct Token: Sendable {
    public let valor: String
    public let expira: Date
    public init(valor: String, expira: Date) { self.valor = valor; self.expira = expira }
    /// Vigente si le quedan más de 30 s.
    public func vigente(_ ahora: Date = Date()) -> Bool { expira.timeIntervalSince(ahora) > 30 }
}

public enum EstadoSolicitud: Int, Codable, Sendable {
    case aceptada = 1, enProceso, terminada, error, rechazada, vencida
}

public struct Verificacion: Sendable {
    public var estado: EstadoSolicitud
    public var codigoEstatus: Int
    public var codigoEstadoSolicitud: Int
    public var numeroCFDIs: Int
    public var mensaje: String
    public var paquetes: [String]
    public init(estado: EstadoSolicitud, codigoEstatus: Int, codigoEstadoSolicitud: Int,
                numeroCFDIs: Int, mensaje: String, paquetes: [String]) {
        self.estado = estado; self.codigoEstatus = codigoEstatus
        self.codigoEstadoSolicitud = codigoEstadoSolicitud; self.numeroCFDIs = numeroCFDIs
        self.mensaje = mensaje; self.paquetes = paquetes
    }
}

/// Una petición al SAT y su respuesta, con el token, la firma y el certificado tapados.
/// Es lo que la app guarda como diagnóstico.
public struct EntradaBitacora: Codable, Sendable {
    public var fecha: Date
    public var operacion: String
    public var url: String
    public var estadoHTTP: Int?
    public var peticion: String
    public var respuesta: String
    public init(fecha: Date, operacion: String, url: String, estadoHTTP: Int?, peticion: String, respuesta: String) {
        self.fecha = fecha; self.operacion = operacion; self.url = url
        self.estadoHTTP = estadoHTTP; self.peticion = peticion; self.respuesta = respuesta
    }
}

public enum SATError: Error, CustomStringConvertible, Sendable {
    case http(Int, String)          // código HTTP y cuerpo
    case fault(String)              // SOAP fault
    case codigo(Int, String)        // CodEstatus / CodigoEstadoSolicitud del SAT y su mensaje
    case respuestaInvalida(String)

    public var description: String {
        switch self {
        case .http(let c, _): return "El SAT respondió HTTP \(c)."
        case .fault(let m): return "El SAT rechazó la petición: \(m)"
        case .codigo(let c, let m): return "SAT \(c): \(m)"
        case .respuestaInvalida(let m): return "Respuesta del SAT que no se entiende: \(m)"
        }
    }
}

// MARK: CFDI

public struct Parte: Codable, Hashable, Sendable {
    public var rfc: String
    public var nombre: String
    public var regimenFiscal: String?
    public var usoCFDI: String?        // solo receptor
    public init(rfc: String, nombre: String, regimenFiscal: String? = nil, usoCFDI: String? = nil) {
        self.rfc = rfc; self.nombre = nombre; self.regimenFiscal = regimenFiscal; self.usoCFDI = usoCFDI
    }
}

public struct Concepto: Codable, Hashable, Sendable {
    public var descripcion: String
    public var cantidad: Decimal
    public var importe: Decimal
    public init(descripcion: String, cantidad: Decimal, importe: Decimal) {
        self.descripcion = descripcion; self.cantidad = cantidad; self.importe = importe
    }
}

public struct CFDI: Codable, Hashable, Sendable {
    public var uuid: String                 // en mayúsculas
    public var version: String              // "4.0" o "3.3"
    public var fecha: Date                  // Fecha del comprobante (hora local de México)
    public var serie: String?
    public var folio: String?
    public var tipoComprobante: String      // I, E, T, N, P
    public var emisor: Parte
    public var receptor: Parte
    public var subTotal: Decimal
    public var descuento: Decimal
    public var total: Decimal
    public var moneda: String
    public var formaPago: String?
    public var metodoPago: String?
    public var ivaTrasladado: Decimal       // impuesto 002, trasladado
    public var isrRetenido: Decimal         // impuesto 001, retenido
    public var ivaRetenido: Decimal         // impuesto 002, retenido
    public var conceptos: [Concepto]
    public init(uuid: String, version: String, fecha: Date, serie: String?, folio: String?,
                tipoComprobante: String, emisor: Parte, receptor: Parte, subTotal: Decimal,
                descuento: Decimal, total: Decimal, moneda: String, formaPago: String?,
                metodoPago: String?, ivaTrasladado: Decimal, isrRetenido: Decimal,
                ivaRetenido: Decimal, conceptos: [Concepto]) {
        self.uuid = uuid; self.version = version; self.fecha = fecha; self.serie = serie
        self.folio = folio; self.tipoComprobante = tipoComprobante; self.emisor = emisor
        self.receptor = receptor; self.subTotal = subTotal; self.descuento = descuento
        self.total = total; self.moneda = moneda; self.formaPago = formaPago
        self.metodoPago = metodoPago; self.ivaTrasladado = ivaTrasladado
        self.isrRetenido = isrRetenido; self.ivaRetenido = ivaRetenido; self.conceptos = conceptos
    }
}

/// Una fila del archivo de Metadata (incluye canceladas).
public struct RegistroMetadata: Codable, Hashable, Sendable {
    public var uuid: String
    public var rfcEmisor: String
    public var nombreEmisor: String
    public var rfcReceptor: String
    public var nombreReceptor: String
    public var fechaEmision: Date?
    public var monto: Decimal
    public var efecto: String               // I, E, T, N, P
    public var vigente: Bool                // Estatus 1 = vigente, 0 = cancelado
    public var fechaCancelacion: Date?
    public init(uuid: String, rfcEmisor: String, nombreEmisor: String, rfcReceptor: String,
                nombreReceptor: String, fechaEmision: Date?, monto: Decimal, efecto: String,
                vigente: Bool, fechaCancelacion: Date?) {
        self.uuid = uuid; self.rfcEmisor = rfcEmisor; self.nombreEmisor = nombreEmisor
        self.rfcReceptor = rfcReceptor; self.nombreReceptor = nombreReceptor
        self.fechaEmision = fechaEmision; self.monto = monto; self.efecto = efecto
        self.vigente = vigente; self.fechaCancelacion = fechaCancelacion
    }
}
