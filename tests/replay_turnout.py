"""Aplica o replay integrado de 24 etapas à variante local de 86 coeficientes."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from contract import read_json
from run_turnout_local import TurnoutPipeline
import replay_pipeline


class VariantTestPipeline(TurnoutPipeline):
    def __init__(self,args):
        config=read_json(ROOT/'local/comparecimento-uf/variant.json')
        args.variant=config
        args.base=args.runtime.parent/(args.runtime.name+'-reports')
        args.base.mkdir(exist_ok=True)
        args.model_code=Path(config['model_source'])
        super().__init__(args)


if __name__=='__main__':
    replay_pipeline.Pipeline=VariantTestPipeline
    replay_pipeline.main()
