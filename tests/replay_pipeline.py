"""Teste integrado opcional com o modelo R instalado; todos os votos são fictícios."""
import csv
import json
import os
from pathlib import Path
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from contract import atomic_write, digest, read_json, validate
from run_local import Pipeline, parser, runtime_lock
from simulate_tse import publish_demo_stage


def main():
    args = parser().parse_args()
    assert args.mode == "demo", "Este teste usa somente a simulação"
    args.runtime = args.runtime or ROOT / "local" / ("validacao-" + uuid.uuid4().hex)
    args.source = args.source or args.model_dir / "data/live/tse_export"
    args.initial_state = args.initial_state or args.model_dir / "data/processed/estado_inicial_v2"
    checks = []
    steps = []
    def check(name, value):
        checks.append({"name": name, "passed": bool(value)})
        assert value, name
    watched = ["previsao_execucao.R", "analise_execucao.R", "online_conjugado.R",
        "data/processed/estado_inicial_v2/manifest.json", "data/processed/estado_inicial_v2/estado.rds"]
    hashes = {f: digest((args.model_dir / f).read_bytes()) for f in watched}
    started = time.monotonic()
    with runtime_lock(args.runtime):
        p = Pipeline(args)
        p.prepare()
        check("Previsão com zero BUs", p.latest["forecast"] is not None and p.latest["counting"]["reported_sections"] == 0)
        initial_share = p.latest["forecast"]["share_a"]
        check("Dois cenários coincidem na prior", p.latest.get("forecast_2022") is not None and
            p.latest["forecast_2022"]["share_a"] == initial_share and
            p.latest["forecast_2022"]["interval"] == p.latest["forecast"]["interval"])
        run_folder = p.runtime
        for stage in range(p.stages):
            if stage:
                publish_demo_stage(p.runtime / "model-source", p.runtime, stage)
                if stage == 8:
                    # Caiu depois da publicação do coletor e antes do ponteiro local.
                    p = Pipeline(args)
                    p.prepare()
                    check("Retomada recupera estágio do export após interrupção", p.stage == stage)
                else:
                    p.update()
                    p.stage = stage
                    p.remember()
            s = validate(p.latest, p.config)
            result = read_json(p.runtime / "pipeline-result.json")
            count = s["counting"]
            forecast = s["forecast"]
            historical = s["forecast_2022"]
            check(f"Etapa {stage}: preserva cenário 2022 do mesmo checkpoint",
                historical["share_a"] == result["share_a_2022"] and
                historical["interval"]["lower"] == result["lower_2022"] and
                historical["interval"]["upper"] == result["upper_2022"] and
                historical["source_snapshot_id"] == forecast["source_snapshot_id"] and
                historical["generated_at"] == forecast["generated_at"])
            check(f"Etapa {stage}: origem demo e identidade consistente", s["mode"] == "demo" and
                count["source"]["area"] == "DEMO" and s["source_snapshot_id"] == result["source_snapshot_id"])
            check(f"Etapa {stage}: preserva média e quantis 95% do modelo", forecast["interval"]["level"] == .95 and
                forecast["share_a"] == result["share_a"] and forecast["interval"]["lower"] == result["lower"] and
                forecast["interval"]["upper"] == result["upper"] and forecast["win_probability_a"] is None)
            check(f"Etapa {stage}: BUs usados pelo executor", count["collected_sections"] == result["observed_sections"] and
                count["reported_sections"] == result["regression_sections"])
            steps.append(dict(stage=stage, reported=count["reported_sections"], share=forecast["share_a"],
                lower=forecast["interval"]["lower"], upper=forecast["interval"]["upper"],
                source_area=result["source_area"], seconds=p.last_seconds))
            if stage == 5:
                before = json.dumps(s, sort_keys=True)
                p.update()
                check("Snapshot repetido é idempotente de ponta a ponta", before == json.dumps(p.latest, sort_keys=True) and
                    read_json(p.runtime / "pipeline-result.json")["processed"] is False)
        with (run_folder / "fixture/truth.csv").open() as stream:
            truth = list(csv.DictReader(stream))
        a = sum(int(r["votos_a"]) for r in truth)
        b = sum(int(r["votos_b"]) for r in truth)
        check("100% coincide com os votos sintéticos sem dupla contagem", p.latest["counting"]["votes_a"] == a and
            p.latest["counting"]["votes_b"] == b and abs(p.latest["forecast"]["share_a"] - 100*a/(a+b)) < 1e-9)
        check("Incerteza desaparece com todas as seções observadas", abs(p.latest["forecast"]["interval"]["upper"] -
            p.latest["forecast"]["interval"]["lower"]) < 1e-9)
        check("Cenário 2022 termina no resultado observado", abs(p.latest["forecast_2022"]["share_a"] - 100*a/(a+b)) < 1e-9 and
            abs(p.latest["forecast_2022"]["interval"]["upper"]-p.latest["forecast_2022"]["interval"]["lower"]) < 1e-9)
        check("Atualização altera a previsão inicial", abs(initial_share - steps[5]["share"]) > .01)
        check("BR e soma UFs atravessam o executor", {s["source_area"] for s in steps} == {"BR", "SOMA_UFS"})
        # A origem sintética não pode ser renomeada para dados TSE reais.
        settings = p.settings()
        settings["mode"] = "tse"
        atomic_write(p.runtime / "settings.json", settings)
        rejected = False
        try:
            p.r("atualizar")
        except RuntimeError:
            rejected = True
        finally:
            atomic_write(p.runtime / "settings.json", p.settings())
        check("Fixture recusada no modo real", rejected)
        check("Módulo original preservado", hashes == {f: digest((args.model_dir / f).read_bytes()) for f in watched})
        report = dict(kind="synthetic_integration_test", checks=checks, steps=steps,
            seconds=round(time.monotonic()-started,3), initial_hashes=hashes,
            final_share=100*a/(a+b), sections=len(truth), draws=args.draws,
            note="Verifica integração de software com dados sintéticos; não mede calibração eleitoral.")
        atomic_write(args.runtime / "verification.json", report)
        print(json.dumps({"passed":len(checks),"stages":len(steps),"seconds":report["seconds"],
                          "report":str(args.runtime / "verification.json")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
