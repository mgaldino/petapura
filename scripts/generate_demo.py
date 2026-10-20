"""Reproduz as fixtures sintéticas a partir dos dados do mockup aprovado."""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from pathlib import Path
import json
from contract import validate

ROOT = Path(__file__).resolve().parents[1]

def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

def counting(percent, a, at, area="DEMO"):
    sections = round(percent * 100)
    valid = sections * 1000
    votes_a = round(valid * a / 100)
    return {"total_sections":10000,"reported_sections":sections,"collected_sections":sections,
            "votes_a":votes_a,"votes_b":valid-votes_a,"valid_votes":valid,
            "generated_at":at,"source":{"name":"Demonstração" if area=="DEMO" else "TSE",
                                          "area":area,"generated_raw":None}}

def main():
    raw = json.loads((ROOT / "mockup/dados_mockup.json").read_text())
    config = json.loads((ROOT / "web/config.json").read_text())
    candidates = {"a":{"id":"13","name":"Candidata A"},"b":{"id":"22","name":"Candidato B"}}
    waiting = {"version":1,"snapshot_id":"aguardando-dados","source_snapshot_id":None,
               "generated_at":None,"mode":"waiting","election":config["expected_election"],
               "candidates":candidates,"counting":None,"forecast":None,"history":[]}
    validate(waiting, config)
    save(ROOT / "web/data/latest.json", waiting)
    save(ROOT / "tests/fixtures/waiting.json", waiting)
    times = ["2026-10-25T21:45:00Z","2026-10-25T23:30:00Z","2026-10-26T01:10:00Z"]
    percentages = [21.8,65.2,93.4]
    xs = [1,2,5,10,15,21.8,30,40,50,60,65.2,75,85,93.4]
    aa = [43.3,44.7,46.2,46.6,47.1,47.6,47.9,48.3,48.8,49.25,49.6,50,50.45,50.8]
    def at_percent(percent):
        bounds = [(0,datetime(2026,10,25,21,tzinfo=timezone.utc))] + [(p,datetime.fromisoformat(t.replace("Z","+00:00"))) for p,t in zip(percentages,times)]
        for (p0,t0),(p1,t1) in zip(bounds,bounds[1:]):
            if percent <= p1:
                return (t0+(t1-t0)*((percent-p0)/(p1-p0))).isoformat(timespec="seconds").replace("+00:00","Z")
        raise ValueError(percent)
    snapshots=[]
    for i, stage in enumerate(raw["stages"]):
        at=times[i];m=stage["two"];source=f"demo-source-{i}"
        f={"model_version":"Demonstração sintética","source_snapshot_id":source,"generated_at":at,
           "share_a":m["point"][0],"interval":{"level":.9,"lower":m["bounds"][0][0],"upper":m["bounds"][0][3]},
           "win_probability_a":m["events"][0],"notes":["Cenários fictícios para avaliar a apresentação; não são previsões eleitorais."]}
        history=[]
        for p,a in zip(xs,aa):
            if p>stage["counted"]:continue
            c=counting(p,a,at_percent(p));h={k:c[k] for k in ("total_sections","reported_sections","votes_a","votes_b","valid_votes")};h.update(snapshot_id=f"demo-partial-{p}",generated_at=at_percent(p));history.append(h)
        s={"version":1,"snapshot_id":f"demo-stage-{i}","source_snapshot_id":source,"generated_at":at,"mode":"demo",
           "election":config["expected_election"],"candidates":candidates,"counting":counting(stage["counted"],m["actual"][0],at),"forecast":f,"history":history}
        snapshots.append(validate(s,config))
    save(ROOT / "web/demo/snapshots.json",snapshots)
    live=deepcopy(snapshots[1]);live["mode"]="live";live["snapshot_id"]="fixture-live-95";live["counting"]["source"]={"name":"TSE","area":"BR","generated_raw":"2026-10-25T20:30:00"};live["forecast"]["interval"]={"level":.95,"lower":47.5,"upper":55.3};live["forecast"]["win_probability_a"]=None
    save(ROOT / "tests/fixtures/live-95.json",validate(live,config))
    prior=deepcopy(live);prior["snapshot_id"]="fixture-zero-bus";prior["counting"]=counting(0,0,prior["generated_at"],"BR");prior["history"]=[]
    save(ROOT / "tests/fixtures/prior.json",validate(prior,config))
    complete=deepcopy(live);complete["snapshot_id"]="fixture-complete";complete["generated_at"]="2026-10-26T02:00:00Z";complete["counting"]=counting(100,51.1,complete["generated_at"],"BR");complete["forecast"]=None
    save(ROOT / "tests/fixtures/complete.json",validate(complete,config))
    save(ROOT / "tests/fixtures/forecast.json",live["forecast"])
    print("Demonstração e fixtures reproduzidas. Todos os valores são sintéticos.")

if __name__ == "__main__":
    main()
