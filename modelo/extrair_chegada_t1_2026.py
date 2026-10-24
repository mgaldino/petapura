"""Horário em que o BU de cada seção do 1º turno de 2026 ficou disponível no TSE.

Fonte (somente leitura): coleta do projeto electoralFraud, arquivos
data/raw/tse/2026/api_bu/20261005T_R1_full/*/*_part*.csv, colunas cs_da e cs_ha
(data e hora do arquivo do BU, horário de Brasília). Primeira ocorrência de cada seção.
Grava data/processed/chegada_t1_2026.csv.gz (uf, cd_mun, zona, secao, recebido);
recebido fica vazio quando cs_da ou cs_ha falta.

Uso: python3 extrair_chegada_t1_2026.py [diretório da coleta]
"""
import csv
import datetime as dt
import gzip
import io
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parents[5] / "Papers" / "electoralFraud" / "data" / "raw" / "tse" / "2026" / "api_bu" / "20261005T_R1_full"
OUT = ROOT / "data" / "processed" / "chegada_t1_2026.csv.gz"


def main(source: Path) -> None:
    seen = set()
    sections = missing = 0
    tmp = OUT.with_suffix(".tmp")
    # mtime=0: o mesmo conteúdo gera o mesmo arquivo comprimido (SHA256 estável).
    with open(tmp, "wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as compressed, \
            io.TextIOWrapper(compressed, encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["uf", "cd_mun", "zona", "secao", "recebido"])
        for path in sorted(source.glob("*/*_part*.csv")):
            with open(path, newline="", encoding="utf-8") as part:
                for row in csv.DictReader(part):
                    key = (row["uf"], int(row["municipio"]), int(row["zona"]), int(row["secao"]))
                    if key in seen:
                        continue
                    seen.add(key)
                    if row["cs_da"] and row["cs_ha"]:
                        received = dt.datetime.strptime(row["cs_da"] + " " + row["cs_ha"], "%d/%m/%Y %H:%M:%S").isoformat()
                    else:
                        received = ""
                        missing += 1
                    writer.writerow([*key, received])
                    sections += 1
    tmp.replace(OUT)
    print("seções", sections, "sem horário", missing)


if __name__ == "__main__":
    main(Path(sys.argv[1]) if len(sys.argv) > 1 else SOURCE)
