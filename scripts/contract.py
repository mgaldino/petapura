"""Contrato público do site. Somente biblioteca padrão; percentuais em 0–100."""
from datetime import datetime
import hashlib
import fcntl
import json
import math
import os
from pathlib import Path
import re
import tempfile

class ContractError(ValueError):
    pass

# Projeção publicada em cada atualização; entradas anteriores a 25/10/2026 podem não ter esses campos.
HISTORY_FORECAST = ("forecast_a", "forecast_lower", "forecast_upper",
                    "forecast_2022_a", "forecast_2022_lower", "forecast_2022_upper")

def require(condition, path):
    if not condition:
        raise ContractError(f"Dado inválido: {path}")

def obj(value, path):
    require(isinstance(value, dict), path)

def keys(value, allowed, path, optional=()):
    obj(value, path)
    require(set(value) <= set(allowed) and set(allowed)-set(optional) <= set(value), path + ".campos")

def text(value, path, maximum=120):
    require(isinstance(value, str) and bool(value.strip()) and len(value) <= maximum, path)

def numeric(value, path, minimum=0, maximum=100):
    require(type(value) in (int, float) and math.isfinite(value) and minimum <= value <= maximum, path)

def count(value, path):
    require(type(value) in (int, float) and math.isfinite(value) and value % 1 == 0 and 0 <= value <= 2**53-1, path)

def stamp(value, path="generated_at"):
    require(isinstance(value, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z", value), path)
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ContractError(f"Dado inválido: {path}") from exc

def counts(value, path):
    obj(value, path)
    for key in ("total_sections", "reported_sections", "votes_a", "votes_b", "valid_votes"):
        count(value.get(key), f"{path}.{key}")
    require(value["total_sections"] > 0 and value["reported_sections"] <= value["total_sections"], path)
    require(value["votes_a"] + value["votes_b"] == value["valid_votes"], path)
    require(value["reported_sections"] > 0 or value["valid_votes"] == 0, path)
    if value.get("collected_sections") is not None:
        count(value["collected_sections"], f"{path}.collected_sections")
        require(value["collected_sections"] <= value["total_sections"], path)

def validate(snapshot, config=None):
    s = snapshot
    config = config or {}
    obj(s, "snapshot")
    keys(s, ("version","snapshot_id","source_snapshot_id","generated_at","mode","election","candidates","counting","forecast","forecast_2022","history"), "snapshot", ("forecast_2022",))
    require(type(s.get("version")) in (int, float) and s["version"] == 1, "version")
    text(s.get("snapshot_id"), "snapshot_id")
    require(s.get("mode") in ("waiting", "live", "demo"), "mode")
    if s.get("generated_at") is not None:
        stamp(s["generated_at"])
    else:
        require(s["mode"] == "waiting", "generated_at")
    if s["mode"] != "waiting":
        text(s.get("source_snapshot_id"), "source_snapshot_id")
    e = s.get("election")
    obj(e, "election")
    keys(e, ("year","round","office","election_id","pleito_id"), "election")
    text(e.get("election_id"), "election.election_id")
    text(e.get("pleito_id"), "election.pleito_id")
    require(type(e.get("year")) in (int,float) and e["year"] == 2026 and type(e.get("round")) in (int,float) and e["round"] == 2 and e.get("office") == "president", "election")
    for key, value in config.get("expected_election", {}).items():
        require(e.get(key) == value, f"election.{key}")
    obj(s.get("candidates"), "candidates")
    keys(s["candidates"], ("a","b"), "candidates")
    for key in ("a", "b"):
        c = s["candidates"].get(key)
        obj(c, f"candidates.{key}")
        keys(c, ("id","name"), f"candidates.{key}")
        text(c.get("id"), f"candidates.{key}.id")
        text(c.get("name"), f"candidates.{key}.name", 80)
        expected = config.get("expected_candidates", {}).get(key)
        require(expected is None or expected == c["id"], f"candidates.{key}.id")
    require(s["candidates"]["a"]["id"] != s["candidates"]["b"]["id"], "candidates")
    require("counting" in s and "forecast" in s, "counting/forecast")
    if s["counting"] is not None:
        c = s["counting"]
        keys(c, ("total_sections","reported_sections","collected_sections","prior_share_a","votes_a","votes_b","valid_votes","generated_at","source"), "counting", ("collected_sections","prior_share_a"))
        counts(c, "counting")
        if "prior_share_a" in c:
            # Previsão sem aprendizado para as seções já apuradas (ver docs/ENTRADA_BU.md).
            numeric(c["prior_share_a"], "counting.prior_share_a")
        stamp(c.get("generated_at"), "counting.generated_at")
        require(stamp(c["generated_at"]) <= stamp(s["generated_at"]), "counting.generated_at")
        obj(c.get("source"), "counting.source")
        keys(c["source"], ("name","area","generated_raw"), "counting.source", ("generated_raw",))
        text(c["source"].get("name"), "counting.source.name")
        require(c["source"].get("area") in (("DEMO",) if s["mode"] == "demo" else ("BR", "SOMA_UFS")), "counting.source.area")
        if c["source"].get("generated_raw") is not None:
            text(c["source"]["generated_raw"], "counting.source.generated_raw")
    if s["forecast"] is not None:
        f = s["forecast"]
        obj(f, "forecast")
        keys(f, ("model_version","source_snapshot_id","generated_at","share_a","interval","win_probability_a","notes"), "forecast")
        numeric(f.get("share_a"), "forecast.share_a")
        text(f.get("model_version"), "forecast.model_version")
        stamp(f.get("generated_at"), "forecast.generated_at")
        text(f.get("source_snapshot_id"), "forecast.source_snapshot_id")
        require(f["source_snapshot_id"] == s.get("source_snapshot_id"), "forecast.source_snapshot_id")
        b = f.get("interval")
        obj(b, "forecast.interval")
        keys(b, ("level","lower","upper"), "forecast.interval")
        numeric(b.get("level"), "forecast.interval.level", .01, .999)
        numeric(b.get("lower"), "forecast.interval.lower")
        numeric(b.get("upper"), "forecast.interval.upper")
        require(b["lower"] <= b["upper"], "forecast.interval")
        require("win_probability_a" in f, "forecast.win_probability_a")
        if f["win_probability_a"] is not None:
            numeric(f["win_probability_a"], "forecast.win_probability_a", 0, 1)
        require(isinstance(f.get("notes"), list) and len(f["notes"]) <= 10 and all(isinstance(v,str) and len(v) <= 1000 for v in f["notes"]), "forecast.notes")
        require(stamp(f["generated_at"]) <= stamp(s["generated_at"]), "forecast.generated_at")
    require(isinstance(s.get("history"), list) and len(s["history"]) <= 4000, "history")
    last = None
    ids = set()
    for i, h in enumerate(s["history"]):
        p = f"history[{i}]"
        keys(h, ("snapshot_id","generated_at","total_sections","reported_sections","votes_a","votes_b","valid_votes") + HISTORY_FORECAST, p, HISTORY_FORECAST)
        counts(h, p)
        for prefix in ("forecast", "forecast_2022"):
            values = [h.get(f"{prefix}_{part}") for part in ("a", "lower", "upper")]
            if all(v is None for v in values):
                continue
            for v in values:
                numeric(v, f"{p}.{prefix}")
            require(values[1] <= values[2], f"{p}.{prefix}")
        text(h.get("snapshot_id"), p + ".snapshot_id")
        t = stamp(h.get("generated_at"), p + ".generated_at")
        require((last is None or last <= t) and h["snapshot_id"] not in ids and s["generated_at"] is not None and t <= stamp(s["generated_at"]), p)
        last = t
        ids.add(h["snapshot_id"])
    if s["mode"] == "waiting":
        require(s["source_snapshot_id"] is None and s["counting"] is None and s["forecast"] is None and not s["history"], "waiting")
    if s.get("forecast_2022") is not None:
        require(s["forecast"] is not None, "forecast_2022 sem forecast")
        alternative = {k: v for k, v in s.items() if k != "forecast_2022"}
        alternative["forecast"] = s["forecast_2022"]
        validate(alternative, config)
        require(s["forecast_2022"]["generated_at"] == s["forecast"]["generated_at"], "cenários de checkpoints diferentes")
    return s

def read_json(path):
    p = Path(path)
    require(p.stat().st_size <= 2_000_000, "arquivo excede 2 MB")
    def bad_constant(value):
        raise ContractError(f"Número JSON inválido: {value}")
    return json.loads(p.read_text(encoding="utf-8"), parse_constant=bad_constant)

def canonical(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":"))

def atomic_write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = (canonical(value) + "\n").encode("utf-8")
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)

def _publish(snapshot, destination, config=None):
    """Um único escritor; publicação atômica e idempotente por snapshot_id."""
    s = json.loads(canonical(validate(snapshot, config)))
    destination = Path(destination)
    previous = validate(read_json(destination), config) if destination.exists() else None
    if previous and previous["mode"] != "waiting":
        require(s["mode"] == previous["mode"], "mudança de modo exige outro destino")
        if s["snapshot_id"] == previous["snapshot_id"]:
            # O histórico é acrescentado pelo publicador, não pelo produtor do modelo.
            a = {k:v for k,v in s.items() if k != "history"}
            b = {k:v for k,v in previous.items() if k != "history"}
            require(a == b, "snapshot_id reutilizado com conteúdo diferente")
            return previous, False
        require(s["generated_at"] is not None and stamp(s["generated_at"]) >= stamp(previous["generated_at"]), "snapshot anterior ao publicado")
    history = previous["history"][:] if previous and previous["mode"] == s["mode"] else s["history"][:]
    if s["counting"] is not None:
        c = s["counting"]
        entry = {key:c[key] for key in ("total_sections", "reported_sections", "votes_a", "votes_b", "valid_votes")}
        entry.update(snapshot_id=s["snapshot_id"], generated_at=s["generated_at"])
        # A projeção de cada atualização permite traçar o caminho desde a previsão inicial.
        for prefix in ("forecast", "forecast_2022"):
            f = s.get(prefix)
            if f is not None:
                entry.update({f"{prefix}_a": f["share_a"], f"{prefix}_lower": f["interval"]["lower"],
                              f"{prefix}_upper": f["interval"]["upper"]})
        if not history or history[-1]["snapshot_id"] != s["snapshot_id"]:
            history.append(entry)
    s["history"] = history[-4000:]
    validate(s, config)
    atomic_write(destination, s)
    return s, True

def publish(snapshot, destination, config=None):
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with (destination.parent / f".{destination.name}.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ContractError("Outro publicador está usando o mesmo destino") from exc
        return _publish(snapshot, destination, config)

def digest(raw):
    return hashlib.sha256(raw).hexdigest()
