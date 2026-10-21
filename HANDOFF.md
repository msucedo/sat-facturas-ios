# HANDOFF: sat-facturas-ios (2026-10-21)

> ## ⏸️ PROYECTO EN PAUSA (2026-10-21)
> **Motivo:** no tengo e.firma. Sin ella no se puede probar nada contra el SAT real, porque la e.firma pública de pruebas (EKU9003173C9) siempre la rechaza.
> **Se retoma cuando:** tenga mi e.firma (cita en el SAT) o alguien con e.firma pueda probar `satctl` o una versión de TestFlight.
>
> **Cómo quedó al pausar** (compila, 24/24 pruebas en verde):
> - Ya está todo esto en SATKit:
>   - **Hecho por mí, revisado:** `SOAPEnvelope` con el sobre de autenticación, verificado con `tools/verifica_sobre.py` (lxml + openssl).
>   - **Escrito por agentes, detenidos a medio trabajo:**
>     - `SOAPEnvelope`: sobres de solicitud, verificación y descarga con firma envuelta.
>     - `DescargaMasiva`: cliente HTTP, `autenticar`, `solicitar`, `verificar`, `descargar`, bitácora tapada.
>     - `ZIP`, `CFDIParser` (4.0 y 3.3), `MetadataParser`, `Exportar` (CSV y ZIP) y `PaqueteSAT`.
>   - **Tipos compartidos:** `SATKit/Modelos.swift`.
> - **Revisar antes de seguir:**
>   - La parte de los agentes no tiene revisión completa.
>   - Es posible que `cli/main.swift` y `DescargaMasivaTests` estén incompletos.
>   - Falta pasar `verifica_sobre.py` por los sobres envueltos.
> - `ios/MisFacturas/` está vacío. La app no se empezó.
> - **Decisiones para retomar:**
>   - Nombre "Mis Facturas" (`com.mariosaucedo.MisFacturas`), sin "SAT" en el nombre por las guías de Apple.
>   - Alcance MVP: descargar, ver y exportar, sin suscripción.
>   - Plan con el contrato de SATKit y las tareas para la app: `~/.claude/plans/hola-retomemos-el-proyecto-tender-sunrise.md`.
>
> Lo de abajo es el estado anterior a la pausa.

## Qué es
Una app de iOS de suscripción que **descarga tus CFDI del SAT con tu e.firma**, los ordena y te avisa (factura nueva, factura cancelada, proveedor EFOS, e.firma por vencer). Usa el webservice oficial de **Descarga Masiva v1.5**. El nombre está por decidir ("Mis Facturas SAT").

- **Plan completo:** `~/.claude/plans/ok-que-me-recomiendas-dynamic-valiant.md`
- **Lectura de las apps de referencia:** `docs/re-notes.md`. Ahí está todo lo que aprendimos de DM4, OneFacture y la app de Android. **Léelo antes de escribir los sobres SOAP.**

## Reglas (no cambian)
- **La e.firma nunca sale del teléfono**: Keychain, sin servidor propio. Es nuestro diferenciador: las tres apps de referencia la mandan a un servidor.
- **Solo webservices oficiales y públicos del SAT**: Descarga Masiva y ConsultaCFDIService. No raspamos portales ni usamos endpoints privados de apps del SAT.
- **Claude no toca tu e.firma real.** Las pruebas con ella las corres tú. Claude usa la e.firma de pruebas pública (EKU9003173C9).
- **Claude no hace commits.** El git es tuyo.
- **Forma de trabajo:** paso a paso, explicando cada pieza, esperando tu "sigue".

## Estado
| Fase | Estado |
|---|---|
| 0. Conseguir las referencias | ✅ APK, DM4 (ClickOnce, .NET) y OneFacture (Electron) en `re/` |
| 1. Leerlas | ✅ `docs/re-notes.md` (secciones 1–8) |
| 2. Núcleo `SATKit` + CLI `satctl` | 🟡 **Paso 1 de varios** hecho: abrir la e.firma y firmar |
| 3. App iOS (SwiftUI) | ⏳ |

**Ya hecho y probado (4/4 pruebas en verde):**
- `SATKit/DER.swift`: lector mínimo de ASN.1/DER.
- `SATKit/EFirma.swift`:
  - `Certificado` saca el RFC, el nombre, el número de certificado, la vigencia, el emisor (`emisor`) y la serie en decimal (`serialDecimal`).
  - `LlavePrivada` descifra el `.key` en el dispositivo (PKCS#8/PBES2 con CommonCrypto) y firma con SHA1 o SHA256.
  - `EFirma` verifica que el `.key` sea la pareja del `.cer`.
- `cli/main.swift`: `satctl efirma <cer> <key>`. La contraseña se pide sin eco o se toma de `SAT_PASSWORD`.
- `Tests/SATKitTests/EFirmaTests.swift` con la e.firma de pruebas en `Tests/SATKitTests/Fixtures/fiel/`. Una prueba compara la firma byte por byte contra la de `openssl`.

## Cómo compilar y probar
```sh
cd ~/Documents/code/sat-facturas-ios
export DEVELOPER_DIR="/Applications/Copia de Xcode.app/Contents/Developer"
swift build
swift test
.build/debug/satctl efirma ruta/tu.cer ruta/tu.key     # con tu e.firma (lo corres tú)
```
Si guardas tu e.firma dentro del proyecto, ponla en `secrets/`, que está en `.gitignore` (igual que `re/` y `descargas/`).

## Siguiente paso: `SOAPEnvelope` + Autenticación → `satctl auth`
Dejarlo listo para que tú lo corras con tu e.firma y recibas un token.
1. **`SATKit/SOAPEnvelope.swift`**, con plantillas fijas armadas como en OneFacture (`re-notes` §3 y §7.1):
   - **Autenticación:** `u:Timestamp u:Id="_0"` (expira en 5 min), digest SHA1 → `SignedInfo` exc-c14n → firma rsa-sha1, `BinarySecurityToken` `uuid-<v4>-4`, `SecurityTokenReference`.
2. **`SATKit/DescargaMasiva.swift`** con `autenticar() -> Token`:
   - POST a `https://cfdidescargamasivasolicitud.clouda.sat.gob.mx/Autenticacion/Autenticacion.svc` con `SOAPAction: "http://DescargaMasivaTerceros.gob.mx/IAutenticacion/Autentica"`.
   - El token sale de `AutenticaResult`. Se guarda junto con su hora de expiración y se reusa durante los 5 minutos.
3. **CLI:** `satctl auth <cer> <key> [--debug]`. Con `--debug` guarda `debug/soap_request.xml` y `debug/soap_response.xml` (la idea viene de DM4).
4. **Prueba unitaria:** con un timestamp y un UUID fijos, el sobre debe salir idéntico al esperado, y la firma debe verificarse con el `.cer`.

**Después:**
- `solicitar(emitidos|recibidos, mes, tipo: CFDI|Metadata)`, siempre las dos juntas.
- `verificar(id)` y `descargar(paquete)`: guardar el ZIP en disco antes de abrirlo.
- Unzip.
- `CFDIParser` (4.0 y 3.3).
- `ConsultaEstatus` (cancelada y EFOS).
- Luego la Fase 3 (la app).

## Decisiones ya tomadas para SATKit (`re-notes` §8)
- **Un mes por solicitud.** Si llega 5003 (más de 200,000 XML), partir el periodo en mitades.
- **Fechas con hora.** Si llega 5002 (repetida "de por vida"), mover `FechaFinal` un segundo y reintentar **una sola vez**. Llevar un registro local de las solicitudes hechas.
- **CFDI y Metadata juntas por periodo.** Cruzar los UUID para encontrar faltantes y canceladas.
- **Paquetes:** guardar el ZIP en disco antes de abrirlo. 5008: un paquete solo se puede bajar 2 veces. 5007: caducan a las 72 h.
- **Verificación automática** en iOS con `BGAppRefreshTask`, con espera creciente, y notificación cuando quede Terminada.

## Dudas por resolver contra el SAT real
- `X509SerialNumber`: ¿decimal (lo que hacemos nosotros) o hexadecimal (DM4)? Y el formato de `X509IssuerName`.
- `ValidacionEFOS`: qué significa cada código (100/200/201/300/400) en ConsultaCFDIService.
- Confirmar atributos v1.5 opcionales: `RfcACuentaTerceros`, `Complemento`, `TipoComprobante`, `Folio`.

## Herramientas de lectura
- `tools/re/ildump.py <ensamblado.exe> <salida.txt>`: vuelca, método por método, las cadenas, llamadas y campos del IL de .NET. Necesita `dnfile` en un venv: `python3 -m venv /tmp/v && /tmp/v/bin/pip install dnfile`.
- `tools/re/asar.py <app.asar> <carpeta>`: extrae el código de una app Electron sin ejecutarla.
- rea: `inspect_managed_members` **tumba el servidor** con el `.exe` de DM4 (12 MB). No repetirlo; usar `ildump.py`.
- Las apps de referencia están en `re/` (`apk/`, `dm4/clickonce/`, `ondefacture/`), fuera de git.

## Pendiente fuera de este proyecto
- HisenseRemote 1.0 y Mi Altar de Muertos 0.3.0 están **en App Review**. Si Apple responde, eso va primero.
