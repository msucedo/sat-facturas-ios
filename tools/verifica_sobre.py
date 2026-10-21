#!/usr/bin/env python3
"""Revisa un sobre de Autenticación sin usar el código de SATKit.

    python3 tools/verifica_sobre.py <sobre.xml> <archivo.cer>

1. Canonicaliza el u:Timestamp con exc-c14n (lxml) y compara su SHA1 con DigestValue.
2. Canonicaliza el SignedInfo y verifica SignatureValue con openssl y la llave del .cer.
Necesita lxml (pip install lxml) y openssl.
"""
import base64, hashlib, subprocess, sys, tempfile, os
from lxml import etree

NS = {
    "u": "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd",
    "ds": "http://www.w3.org/2000/09/xmldsig#",
}

def c14n(el):
    return etree.tostring(el, method="c14n", exclusive=True, with_comments=False)

def main(sobre, cer):
    doc = etree.parse(sobre)
    ts = doc.find(".//u:Timestamp", NS)
    si = doc.find(".//ds:SignedInfo", NS)
    digest = doc.findtext(".//ds:DigestValue", namespaces=NS)
    firma = base64.b64decode(doc.findtext(".//ds:SignatureValue", namespaces=NS))

    calculado = base64.b64encode(hashlib.sha1(c14n(ts)).digest()).decode()
    ok_digest = calculado == digest
    print(f"digest:  {'OK' if ok_digest else 'NO'}  ({calculado} vs {digest})")

    with tempfile.TemporaryDirectory() as d:
        pub, sig, dat = (os.path.join(d, n) for n in ("pub.pem", "firma.bin", "signedinfo.xml"))
        pem = subprocess.run(["openssl", "x509", "-inform", "DER", "-in", cer, "-pubkey", "-noout"],
                             check=True, capture_output=True).stdout
        open(pub, "wb").write(pem)
        open(sig, "wb").write(firma)
        open(dat, "wb").write(c14n(si))
        r = subprocess.run(["openssl", "dgst", "-sha1", "-verify", pub, "-signature", sig, dat],
                           capture_output=True, text=True)
    ok_firma = r.returncode == 0
    print(f"firma:   {'OK' if ok_firma else 'NO'}  ({r.stdout.strip() or r.stderr.strip()})")
    sys.exit(0 if ok_digest and ok_firma else 1)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
