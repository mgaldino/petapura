"""Cópia consistente dos fontes do modelo por execução; checkpoints não mudam de API."""
import json
from pathlib import Path
import re
import shutil
import tempfile

from contract import atomic_write, digest, require

EXTENSIONS = {".R", ".py", ".json", ".stan"}


def source_files(directory):
    return {p.name: p.read_bytes() for p in sorted(Path(directory).iterdir())
            if p.is_file() and p.suffix in EXTENSIONS and p.name != "source-manifest.json"}


def freeze_model(directory, destination):
    directory, destination = Path(directory).resolve(), Path(destination)
    require(not destination.exists(), "cópia do modelo já existe")
    require(not destination.resolve().is_relative_to(directory), "cópia dentro do modelo original")
    parent_manifest = verify_model(directory) if (directory / "source-manifest.json").exists() else None
    for _ in range(3):
        files = source_files(directory)
        # Arquivos apontados por defaults em R precisam acompanhar os fontes.
        referenced = set(re.findall(rb'["\']([^"\'/]+\.json)["\']',
                                    b"\n".join(v for k, v in files.items()
                                               if k in {"componentes_locais.R", "online_conjugado.R"})))
        missing = {v.decode() for v in referenced if v.decode() not in files and
                   v.startswith((b"componentes_locais_", b"escalas_online_"))}
        if files == source_files(directory) and not missing:
            break
    else:
        raise ValueError("Os fontes/configurações do modelo mudaram durante a cópia; tente novamente")
    require("previsao_execucao.R" in files, "API de previsão ausente")
    destination.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix=".model-source-", dir=destination.parent))
    try:
        for name, raw in files.items():
            (tmp / name).write_bytes(raw)
        atomic_write(tmp / "source-manifest.json", {"kind": "pet_frozen_model_source",
            "original": parent_manifest["original"] if parent_manifest else str(directory),
            "files": {k: digest(v) for k, v in files.items()}})
        tmp.rename(destination)
    finally:
        if tmp.exists():
            shutil.rmtree(tmp)
    verify_model(destination)


def verify_model(directory):
    directory = Path(directory)
    manifest = json.loads((directory / "source-manifest.json").read_text(encoding="utf-8"))
    require(manifest.get("kind") == "pet_frozen_model_source", "cópia do modelo sem identificação")
    for name, expected in manifest["files"].items():
        require(Path(name).name == name, "caminho do fonte congelado")
        require(digest((directory / name).read_bytes()) == expected, f"fonte congelado alterado: {name}")
    return manifest
