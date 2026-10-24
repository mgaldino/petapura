"""Preserva um BU real T1 de dois candidatos para testar BER sem rede."""
import csv
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parent
SOURCE = Path.home() / "Documents/DCP/Papers/electoralFraud/data/raw/tse/2026/api_bu/20261005T_R1_full/AC"


def main():
    dest = ROOT / "fixtures"
    dest.mkdir(exist_ok=True)
    for manifest in sorted(SOURCE.glob("AC_*.csv")):
        with manifest.open() as stream:
            for row in csv.DictReader(stream):
                if (int(row["municipio"]),int(row["zona"]),int(row["secao"])) != (1040,4,182) or not row["bu_sha256"]:
                    continue
                with zipfile.ZipFile(manifest.with_suffix(".zip")) as archive:
                    raw = archive.read("bu/" + row["bu_name"])
                assert hashlib.sha256(raw).hexdigest() == row["bu_sha256"]
                (dest / "bu_real_t1.dat").write_bytes(raw)
                (dest / "bu_real_t1.json").write_text(json.dumps({"manifest":str(manifest),"row":row,
                    "expected":{"aptos":263,"comparecimento":188,"validos":178,"votos_a":110,"votos_b":68,"brancos":1,"nulos":9}},indent=2))
                return
    raise RuntimeError("BU da fixture não localizado")


if __name__ == "__main__":
    main()
