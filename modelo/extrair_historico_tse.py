"""Extrai votos de presidente por município e zona dos arquivos de dados abertos do TSE.

Fonte: https://cdn.tse.jus.br/estatistica/sead/odsele/ (votacao_candidato_munzona_ANO.zip e
detalhe_votacao_munzona_ANO.zip), baixados em data/historico_tse/raw/ com SHA256 no manifesto.
Lê o BRASIL.csv de cada zip em fluxo, sem descompactar, e grava só CD_CARGO = 1.

Uso: python3 extrair_historico_tse.py
"""
import csv
import io
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parent
RAW = ROOT / "data" / "historico_tse" / "raw"
OUT = ROOT / "data" / "historico_tse"
YEARS = (2006, 2010, 2014, 2018)


def rows(zip_path):
    with zipfile.ZipFile(zip_path) as archive:
        name = next(n for n in archive.namelist() if n.endswith("_BRASIL.csv"))
        with archive.open(name) as raw:
            for row in csv.DictReader(io.TextIOWrapper(raw, encoding="latin-1", newline=""), delimiter=";"):
                if row["CD_CARGO"] == "1":
                    yield row


def write(path, fields, records):
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        count = 0
        for record in records:
            writer.writerow(record)
            count += 1
    tmp.replace(path)
    return count


def main():
    for year in YEARS:
        candidate = write(OUT / f"presidente_candidato_munzona_{year}.csv",
            ["ano", "turno", "uf", "cd_municipio", "zona", "nr_candidato", "sg_partido", "votos"],
            ({"ano": r["ANO_ELEICAO"], "turno": r["NR_TURNO"], "uf": r["SG_UF"], "cd_municipio": r["CD_MUNICIPIO"],
              "zona": r["NR_ZONA"], "nr_candidato": r["NR_CANDIDATO"], "sg_partido": r["SG_PARTIDO"],
              "votos": r["QT_VOTOS_NOMINAIS"]} for r in rows(RAW / f"votacao_candidato_munzona_{year}.zip")))
        detail = write(OUT / f"presidente_detalhe_munzona_{year}.csv",
            ["ano", "turno", "uf", "cd_municipio", "zona", "secoes", "aptos", "comparecimento", "validos", "brancos", "nulos"],
            ({"ano": r["ANO_ELEICAO"], "turno": r["NR_TURNO"], "uf": r["SG_UF"], "cd_municipio": r["CD_MUNICIPIO"],
              "zona": r["NR_ZONA"], "secoes": r["QT_SECOES_PRINCIPAIS"], "aptos": r["QT_APTOS"],
              "comparecimento": r["QT_COMPARECIMENTO"], "validos": r["QT_TOTAL_VOTOS_VALIDOS"],
              "brancos": r["QT_VOTOS_BRANCOS"], "nulos": r["QT_TOTAL_VOTOS_NULOS"]}
             for r in rows(RAW / f"detalhe_votacao_munzona_{year}.zip")))
        print(year, "candidatos:", candidate, "detalhe:", detail, flush=True)


if __name__ == "__main__":
    main()
