# Notas de lectura (Fase 1)

Leímos dos apps que ya descargan CFDI para entender lo que la documentación del SAT no cuenta. **No copiamos código**: anotamos qué hacen, con la evidencia (clase::método), y lo escribimos nuestro en SATKit.

Las referencias están en `re/`, que git ignora:

| App | Qué es | Archivo |
|---|---|---|
| "Descarga Masiva CFDI" (Android) | `com.tecsolt.descarga_masiva` v1.4 | `re/apk/com.tecsolt.descarga_masiva.apk` (sacado del .xapk) |
| Descarga Masiva DM4 (Windows) | .NET Framework 4.6.2, WPF, ClickOnce v1.0.0.35, **sin ofuscar** | `re/dm4/clickonce/DescargaMasivaDM4.exe` (de su publicación pública `elcfdi.com/DMProof/`, sin ejecutarlo) |

**Cómo se leyó DM4:** rea identificó el ensamblado (`inspect_managed_artifact`: .NET 4.6.2, 30 referencias). Pero `inspect_managed_members` tumbó el servidor de rea dos veces con este .exe de 12 MB. Por eso la lista de métodos salió de un volcador propio con `dnfile` (venv en el scratchpad de la sesión, `ildump.py`). El volcador recorre el IL de los 6,731 métodos y anota en cada uno sus `ldstr`, sus llamadas y los campos que toca. Las citas `Clase::Método` de abajo vienen de ese volcado.

## 1. La app Android no sirve como referencia del protocolo
- Es un **WebView** que abre `https://descarga.masivacfdis.com/` (cadena en `classes.dex`; clases `MainActivity$WebAppInterface`, `MainActivityBackup$MyBrowser`). No trae ninguna lógica del SAT.
- El usuario **sube su e.firma a un servidor ajeno**. Es lo contrario de nuestra regla y es un **argumento de venta**: "tu e.firma nunca sale de tu iPhone".

## 2. Mapa de DM4

| Área | Clases | Qué hace |
|---|---|---|
| Portal CFDI (raspado) | `DescargaMasivaController`, `ViewModels.DescargaEOViewModel` | Login en el portal con WebView2, **resuelve el captcha** (`ResolveSatCaptchaAsync`, `TryAutoGetCaptchaAsync`), llena el formulario por fechas con JS inyectado y baja los XML. Límite de 2,000 al día y 500 por consulta (`HandleDailyLimitAsync`, `VerificarLimiteRegistrosAsync`). |
| Webservice (sobres) | `RlSistemas.{Autenticacion, Solicitud, VerificaSolicitud, DescargarSolicitud, SoapRequestBase}` | Arma los sobres SOAP como texto, los firma y los envía con `HttpWebRequest`. |
| Webservice (async) | `GheartSistemas.{AutenticacionService, SolicitudService, VerificacionService, DescargaService, SoapRequestHelper}` | Capa `Task.Run` encima de `RlSistemas`. `SolicitarEmitidosAsync` y `SolicitarRecibidosAsync` llaman a `modFunciones::GenerarSolicitud`. |
| Pantalla del webservice | `Views.WebServiceView` | Botones Solicitar, Verificar, Descargar y Eliminar. Tabla de solicitudes guardada localmente (`PersistenciaService`). |
| Descarga automática | `Services.Auto.*` | **En su nube**: `CloudApiClient` → `https://dm4-descarga-cloud.azurewebsites.net/` (`programaciones`, `ejecuciones`, `paquetes/`, `SubirFielAsync` sube el **PFX + contraseña**). Usa también un servicio de Windows (`DescargaMasivaDM4AutoService`). |
| Estatus y EFOS | `Services.Admin.SatStatusBatchService` | ConsultaCFDIService del SAT, por lotes con `SemaphoreSlim`. |
| Administrar y reportes | `Services.Admin.*`, `Models.Admin.*` | SQLite (`CfdiRepository`, `CfdiBatchWriter`), parser de todos los complementos (Nómina, Pagos 2.0, Carta Porte 2.0/3.0/3.1, Comercio Exterior…), conciliación, Excel (OpenXml), PDF (QuestPDF). |
| Licencias | `Services.Licencia.*` | API `cfdifacturas.com.mx/wapidescarga4/`, cobro con Conekta en web, clave UUID por número de RFC, vigencia, **prueba gratis de 180 días**. |

## 3. El webservice, tal como lo usa DM4

**Endpoints** (`modVariables::.cctor`):
| Operación | URL | SOAPAction |
|---|---|---|
| Autenticación | `https://cfdidescargamasivasolicitud.clouda.sat.gob.mx/Autenticacion/Autenticacion.svc` | `http://DescargaMasivaTerceros.gob.mx/IAutenticacion/Autentica` |
| Solicitud | `https://cfdidescargamasivasolicitud.clouda.sat.gob.mx/SolicitaDescargaService.svc` | `http://DescargaMasivaTerceros.sat.gob.mx/ISolicitaDescargaService/SolicitaDescarga` **+ tipo** |
| Verificación | `https://cfdidescargamasivasolicitud.clouda.sat.gob.mx/VerificaSolicitudDescargaService.svc` | `http://DescargaMasivaTerceros.sat.gob.mx/IVerificaSolicitudDescargaService/VerificaSolicitudDescarga` |
| Descarga | `https://cfdidescargamasiva.clouda.sat.gob.mx/DescargaMasivaService.svc` | `http://DescargaMasivaTerceros.sat.gob.mx/IDescargaMasivaTercerosService/Descargar` |

✅ **Corrección a la primera versión de estas notas:** DM4 **sí usa la v1.5**. `RlSistemas.Solicitud::Generate` arma `"<des:SolicitaDescarga" + tipo + ">"`, con `tipo` igual a `Emitidos` o `Recibidos`, y `GetResult` lee `"SolicitaDescarga" + tipo + "Result"`. La cadena suelta `SolicitaDescarga` era solo el prefijo.

**Truco de DM4:** sus plantillas llevan **espacios de ancho cero (`​`)** después de cada `<` (por ejemplo `<​des:solicitud`), para que no salgan al buscar cadenas. Los quita `CleanInvisible` y `SoapRequestBase::Send` (también `‌` y `‍`) justo antes de calcular el digest y enviar. Para nosotros no tiene importancia, pero explica por qué el primer `strings` mostraba trozos raros.

**Autenticación** (`RlSistemas.Autenticacion::Generate`):
1. `u:Timestamp` con `u:Id="_0"`, `Created` = ahora en UTC (`yyyy-MM-ddTHH:mm:ss.fffZ`) y `Expires` = ahora + N segundos (`AddSeconds`; el valor es un double que el volcador no muestra, se supone de 300 s).
2. Digest SHA1 del Timestamp canonicalizado → `SignedInfo` (exc-c14n, rsa-sha1, `Reference URI="#_0"`) → firma RSA-SHA1 PKCS#1 sobre el `SignedInfo`.
3. Sobre: `s:Header/o:Security s:mustUnderstand="1"` con el Timestamp, un `o:BinarySecurityToken u:Id="uuid-<GUID>-4"` (el certificado en base64) y la `Signature`, cuyo `KeyInfo/o:SecurityTokenReference/o:Reference URI="#uuid-…"` apunta al token. Body `<Autentica xmlns="http://DescargaMasivaTerceros.gob.mx"/>`.
4. Respuesta: el token es el `InnerXml` de `AutenticaResult`. En error se lee el atributo `Mensaje`.

**Solicitud** (`RlSistemas.Solicitud::Generate`, `modFunciones::GenerarSolicitud`):
- Atributos: `EstadoComprobante`, `FechaInicial`, `FechaFinal`, `TipoSolicitud` (`CFDI` o `Metadata`), `RfcEmisor`, `RfcReceptor` y `RfcSolicitante`. Las fechas van `yyyy-MM-dd` + `FixFecha` → `T00:00:00` / `T23:59:59`.
- `EstadoComprobante`: las cadenas `Emitidos` / `Vigente` / `Todos` van juntas. Lo coherente con la v1.5 es **Recibidos + CFDI → `Vigente`** (los recibidos en XML solo pueden ser vigentes) y Emitidos → `Todos`. Lo confirmamos con la documentación.
- Firma **envuelta dentro de `des:solicitud`**: digest SHA1 del nodo `des:solicitud` sin la firma, `Reference URI="#_0"` (sic: DM4 deja `#_0` aunque no haya Id; la documentación usa `URI=""`, y seguimos la documentación), y `KeyInfo/X509Data` con `X509IssuerSerial` (`X509IssuerName` = `cert.Issuer` de .NET, `X509SerialNumber` = `cert.SerialNumber` de .NET, **en hexadecimal**) más el `X509Certificate`. Ojo: nosotros calculamos la serie en decimal, como pide XML-DSig. Hay que probar cuál acepta el SAT.
- `s:Header` vacío; el token va en el header HTTP `Authorization: WRAP access_token="<token>"`.
- Respuesta `SolicitaDescarga<tipo>Result`: `CodEstatus` 5000 = éxito, con `IdSolicitud`. Si no, `"Sat rechazó: " + CodEstatus + " → " + Mensaje`.

**Verificación** (`RlSistemas.VerificaSolicitud::GetResult`):
- `EstadoSolicitud` (entero) → 1 Aceptada · 2 En Proceso · 3 Terminada · 4 Error · 5 Rechazada · 6 Vencida.
- También lee `CodEstatus`, `CodigoEstadoSolicitud`, `NumeroCFDIs`, `Mensaje` e `IdsPaquetes` (varios nodos).
- Tabla de mensajes: 300 Usuario No Válido · 301 XML Mal Formado · 302 Sello Mal Formado · 303 Sello no corresponde con RFC Solicitante · 304 Certificado Revocado o Caducado · 305 Certificado Inválido · 5000 Solicitud recibida con éxito · 5004 No se encontró la Solicitud.

**Descarga** (`RlSistemas.DescargarSolicitud`): `des:peticionDescarga RfcSolicitante IdPaquete`. Respuesta: header `h:respuesta` con `CodEstatus` (5000 = OK) y `Mensaje`, más el nodo `Paquete` = ZIP en base64 (`DescargaService` hace `Convert.FromBase64String`). Los ZIP se extraen en carpetas `yyyy-MM` / `Emitidos|Recibidos[Metadata]`.

**HTTP** (`SoapRequestBase::WebRequest` / `Send`): POST, `Content-Type: text/xml;charset=UTF-8`, `SOAPAction` entre comillas, TLS 1.2 (`SecurityProtocol = 3072`), sin `Expect: 100-continue`. En error HTTP guarda el cuerpo en `debug/soap_response_error.xml` y siempre escribe `debug/soap_request.xml`. **Copiamos esa idea para `satctl --debug`.** `GheartSistemas.SoapRequestHelper` además adjunta el certificado como certificado de cliente TLS. No parece necesario (el SAT autentica por la firma), pero lo anotamos por si falla algo.

## 4. Lo que la documentación no dice: cómo lo maneja DM4

**Validaciones antes de solicitar** (`WebServiceView::BtnSolicitar_Click`):
- No se permiten fechas futuras ("El SAT no permite consultar periodos futuros").
- La fecha inicial no puede ser mayor que la final.
- **El rango tiene que caber en un mismo mes (y año)**. DM4 nunca pide más de un mes por solicitud, así que no necesita partir periodos: lo resuelve con una solicitud por mes.
- **No repite una solicitud idéntica el mismo día** ("Ya existe una solicitud idéntica en proceso para hoy"). Es la defensa contra el límite de solicitudes repetidas del SAT (5002). Guarda las solicitudes localmente.

**Verificación y descarga manuales**: no hay sondeo automático ni Polly en el webservice. El usuario aprieta "Verificar" y, si el estado es Terminada y hay paquetes, "Descargar". En cada operación pide un token nuevo ("Autenticando…"). Polly solo se usa en el raspado del portal, la nube, las licencias y la descarga de XSLT.

**Descarga automática en su nube** (`Services.Auto`):
- Programación diaria, semanal (día de la semana) o mensual (día del mes "para tener los XMLs"), por el **mes anterior completo** o por dos o tres meses atrás.
- Estados de una ejecución: Pendiente → Solicitada → Verificando → Lista para descargar → Descargada | **Vencida (timeout)** | Error.
- Para eso **sube la FIEL (PFX + contraseña) a Azure**. Al terminar, DM4 baja los paquetes y la nube los purga.

→ **Nosotros:** la misma idea (programación mensual, "mes anterior completo") pero **en el teléfono**, con `BGAppRefreshTask` y la e.firma en el Keychain. Es el corazón del plan Pro y nuestro diferenciador.

## 5. Estatus del CFDI y EFOS (sin e.firma)
`SatStatusBatchService`:
- POST a `https://consultaqr.facturaelectronica.sat.gob.mx/ConsultaCFDIService.svc`, `SOAPAction: http://tempuri.org/IConsultaCFDIService/Consulta`, timeout de 30 s.
- Body: `<Consulta xmlns="http://tempuri.org/"><expresionImpresa><![CDATA[?re=<RFC emisor>&rr=<RFC receptor>&tt=<total con formato F6>&id=<UUID>]]></expresionImpresa></Consulta>`. Escapa `&` como `&amp;` en los RFC.
- Respuesta `ConsultaResult`: `CodigoEstatus`, `Estado` (Vigente/Cancelado), `EsCancelable`, `EstatusCancelacion` y **`ValidacionEFOS`**.
- **EFOS viene en la misma respuesta**, sin descargar la lista 69-B. `MapearEfos` agrupa los códigos `100` / `300` / `400` contra `200` / `201` y los traduce a Definitivo / Presunto / Limpio. La correspondencia exacta de cada código está por confirmar con respuestas reales.
- Corre por lotes en paralelo con un `SemaphoreSlim`.

→ **Para el Pro:** "factura cancelada" y "proveedor EFOS" con un solo servicio público. Lo hacemos en `SATKit` (`ConsultaEstatus`).

## 6. Lo que DM4 cobra: ideas para el plan Pro
Validaciones por CFDI (en `Cfdi` de SQLite y `CfdiRow::Bandera`): `EstadoSat`, `EfosEmisor`, `SelloEmisorValido`, `SelloSatValido` (con las XSLT de cadena original que baja `SatResourceDownloader`), `AritmeticaValida`, `PlazoTimbradoValido`, y duplicados por hash o por `Serie+Folio+RfcEmisor`. Todo se junta en un filtro de "CFDI con riesgo".

**En orden de valor e impacto para nosotros:**
1. Alerta de **cancelada** y **EFOS** (ConsultaCFDIService).
2. Descarga mensual automática en el teléfono.
3. Duplicados y aritmética.
4. La validación de sellos queda para después: necesita XSLT, y iOS no tiene un motor público.

**Modelo de cobro de DM4:** licencia anual por número de RFC, prueba de 180 días y pago web con Conekta. Nosotros: suscripción con StoreKit (Pro y Contador para varios RFC).

## 7. OneFacture CFDI 4.7.0 (Electron)
Archivos: `re/ondefacture/onefacture cfdi-4.7.0-universal.dmg` y `… Setup 4.7.0.exe`. El DMG se montó en solo lectura y su `app.asar` se extrajo con un script propio (Python, sin ejecutar nada) al scratchpad de la sesión. El `.exe` es el instalador de Windows de la misma app Electron y no se abrió aparte.

**Piezas:**
- `node_modules/@onefacture/sat-bridge` 1.0.44 (TS → webpack): `SATWebService`, `LoginFIEL`, y además raspado de portales con Playwright y cheerio (Portal CFDI, constancia, opinión 32-D, declaraciones, retenciones).
- `app_legacy/src/libs/constants/SATWebService.js` (v1, legible), el worker `app_legacy/src/__compiled__core__/SAT/scrapper/workers/satWebService.js` y la UI AngularJS en `app_legacy/src/assets/dist/js/app.js`.
- `out/main/workers/*`: declaraciones mensuales y anuales, constancia, opinión, captcha… todo por portal.

### 7.1 Sobres v1.5: la referencia más limpia de las tres
`sat-bridge` (`SATWebService`, función `h`) arma:
- **Solicitud** `des:SolicitaDescargaEmitidos|Recibidos`, con SOAPAction `…/ISolicitaDescargaService/SolicitaDescargaEmitidos` o `…Recibidos`.
  - Atributos: `EstadoComprobante`, `FechaInicial`, `FechaFinal`, `TipoSolicitud` y **`RfcEmisor` (emitidos) o `RfcReceptor` (recibidos)**. **No manda `RfcSolicitante`** en la solicitud v1.5 (DM4 sí).
  - **Recibidos** lleva el hijo `<RfcReceptores><RfcReceptor>RFC</RfcReceptor></RfcReceptores>`. **Emitidos** lleva `<RfcReceptores/>` en el digest y la lista de receptores solo si se filtra.
  - `EstadoComprobante`: por omisión `Todos`, `0` = Cancelado, `1` = Vigente, y **recibidos + Todos se fuerza a `Vigente`**. Esto confirma la regla v1.5 que suponíamos con DM4.
  - Firma: `Reference URI=""` con **`enveloped-signature`**, C14N inclusivo en el `SignedInfo`, rsa-sha1 / sha1. El digest es del elemento `des:SolicitaDescarga…` completo, sin la firma.
- **Verificación** `des:VerificaSolicitudDescarga/des:solicitud IdSolicitud RfcSolicitante` y **Descarga** `des:PeticionDescargaMasivaTercerosEntrada/des:peticionDescarga IdPaquete RfcSolicitante`. Las dos con `Reference URI=""` y exc-c14n.
- **Autenticación**: idéntica a DM4 (Timestamp `_0`, **expira a los 5 minutos**, `uuid-<v4>-4`, `SecurityTokenReference`).
- **`X509SerialNumber` e `X509IssuerName`** salen de `LoginFIEL.certX509.getNumSerie()` / `getIssuerString()`. Formato por confirmar.
- **HTTP**: `Cache-Control: no-cache`, `Content-Type: text/xml; charset=UTF-8`, `Accept: text/xml`, timeout de 65 s.
- **Retenciones**: los mismos sobres contra `retendescargamasivasolicitud.clouda.sat.gob.mx` y `retendescargamasiva.clouda.sat.gob.mx`. **Es una función que podemos agregar casi gratis.**
- **Parseo**: quitan el `xmlns` por omisión, prefijan `s:` y leen con XPath (`//s:SolicitaDescargaResult//@*`, `//s:IdsPaquetes//text()`, `string(//s:Paquete)`).

### 7.2 Códigos del SAT con su significado práctico
De `app.js` y del worker (son los mensajes que ve el usuario):
| Código | Significado | Qué hacer |
|---|---|---|
| 5000 | Solicitud recibida con éxito | — |
| 5001 | Tercero no autorizado | — |
| **5002** | **Se agotaron las solicitudes de por vida para esta consulta** | Cambiar el rango: "agregar un día o un minuto". **Las fechas llevan hora, así que mover un segundo crea una consulta nueva.** |
| **5003** | La solicitud supera el tope por petición (**200,000 XML**) | Reducir el rango (llega como `CodigoEstadoSolicitud` de una solicitud Rechazada) |
| 5004 | No se encontraron XML | No es error. El SAT a veces manda paquetes vacíos: se sigue y luego se cruza contra la Metadata. |
| 5005 | Solicitud duplicada | Reusar la existente |
| 5006 | Error interno del SAT | Reintentar más tarde |
| **5007** | El paquete ya no existe: **viven 72 horas** | Volver a solicitar |
| **5008** | **Un paquete solo se puede descargar 2 veces** | Guardar el ZIP en disco antes de procesarlo; nunca bajarlo dos veces "por si acaso" |
| 404 | Error desconocido | — |

### 7.3 Orquestación
- **Por cada periodo hace dos solicitudes: `CFDI` y `Metadata`** (`$scope.doDownloadRequest`). Las guarda juntas en SQLite (`uuidCfdiRequest`, `uuidMetaRequest`). La Metadata trae todos los UUID (con cancelados) y sirve para detectar los XML que faltan y las cancelaciones. **Buena práctica: la copiamos.**
- La verificación es manual o se dispara justo después de solicitar (`syncRequestStatus`). En cada operación vuelve a hacer `init` + `authenticate`.
- Descarga: bajan **primero todos los ZIP a disco** y después extraen (`SYNC_PACKAGES`: `_fnForDownloadZipsPackages` → `_fnForExtractXmlsZipsPackages`). Organizan por `tipo/año/"MM MES"` y dejan que el usuario arme sus propias carpetas y nombres con campos del CFDI.
- Los errores del SAT se suben a su servidor (`OnlineErrorLogsService.addError`, `cloudfunctions …/log-remote-error`), con todo y la respuesta.
- **Flujo nuevo**: la vista local del webservice está marcada como `sat-ws-deprecated`. Ahora el desktop consulta `…cloudfunctions…/v2/customerapp/get-computer-desktop-sat-wsrequest`, o sea que **las solicitudes las hace su nube** (igual que la descarga automática de DM4).

### 7.4 ⚠️ Privacidad y seguridad (para nuestro marketing, no para copiar)
- **`SATWebService.init()` manda el `.key` (base64) y la contraseña** a `https://apiv2-…run.app/v1/openssl/convert-key-der-to-pem` solo para convertir la llave a PEM, salvo que ya tenga el PEM guardado. Nosotros desciframos la llave en el teléfono (`EFirma.swift`, ya hecho).
- **Las peticiones al SAT van con `strictSSL: false`** (sin verificar el certificado TLS).
- El paquete publicado trae un `test.js` con **rutas, nombres de archivo y contraseñas reales de e.firmas de terceros**, y el bundle trae un `client_secret` OAuth de la app móvil del SAT. **No los copiamos ni los usamos.** Solo dejamos constancia de que existen.
- También usa servicios propios para resolver el captcha del portal (`onefacture-ml-api…/predict-captcha`) y para leer la constancia (`extractor-csf…`).

→ **Argumento de venta frente a las dos apps de escritorio y la de Android:** "tu e.firma nunca sale de tu iPhone: ni a nuestra nube (no tenemos) ni a la de nadie".

## 8. Comparativo y decisiones para SATKit
| Tema | DM4 | OneFacture | **Nosotros** |
|---|---|---|---|
| Solicitud v1.5 | Sí (manda `RfcSolicitante` de más) | Sí, la más fiel a la documentación | Plantilla tipo OneFacture: `RfcEmisor`/`RfcReceptor` + `RfcReceptores`, `URI=""` + enveloped |
| Rango por solicitud | Máximo 1 mes | El que elija el usuario | **1 mes por solicitud**; si llega 5003, partir en mitades |
| Fechas | Día completo | Con hora y segundos | Con hora: permite el truco contra 5002 |
| Repetidas (5002) | No repite el mismo día | Le dice al usuario "agrega un día o un minuto" | Llevar registro local de solicitudes; si llega 5002, **mover `FechaFinal` un segundo** y reintentar una vez |
| CFDI + Metadata | Separadas, a mano | **Ambas juntas por periodo** | Ambas juntas; cruzar UUIDs para faltantes y canceladas |
| Paquetes | Bajar y extraer | **Primero todo a disco**, luego extraer | Guardar el ZIP antes de abrirlo (5008: solo 2 descargas), y tener en cuenta que caduca a las 72 h (5007) |
| Verificación | Botón | Botón o al solicitar | Automática: `BGAppRefreshTask` con espera creciente, y notificación al quedar Terminada |
| Token | Uno nuevo por operación | Uno nuevo por operación | Reusar mientras no pasen 5 minutos |
| e.firma | PFX local; a Azure si hay descarga automática | **`.key` y contraseña a su servidor**; nube para el flujo nuevo | **Solo en el Keychain del iPhone** |
| Retenciones | No | Sí | Más adelante (mismos sobres, otros hosts) |
| Estatus/EFOS | ConsultaCFDIService | Por su API (`cfdis-cancellations/getCfdiStatus`) | ConsultaCFDIService directo |

## 9. Pendiente
- [ ] Confirmar contra la documentación v1.5: el `EstadoComprobante` de Recibidos, `Reference URI=""` contra `#_0`, la serie en decimal o en hexadecimal y los atributos nuevos (`RfcACuentaTerceros`, `Complemento`, `TipoComprobante`, `Folio`).
- [ ] La correspondencia de `ValidacionEFOS` (100, 200, 201, 300, 400) con respuestas reales.
