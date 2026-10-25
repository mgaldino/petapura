"""Execução isolada e somente local do modelo com comparecimento variando por UF."""
from datetime import datetime, timezone
from functools import partial
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from urllib.parse import urlsplit

from contract import atomic_write, digest, read_json, require
from model_runtime import freeze_model, source_files, verify_model
from run_local import Pipeline, Handler, ROOT, parser, runtime_lock

EXPERIMENT = ROOT / 'experimentos/comparecimento_uf'
LABEL = 'br.usp.petapura.turnout-uf'


def prepare_variant(args):
    base = args.base.resolve()
    production = read_json(ROOT/'local/cloudflare-production/current.json')
    source = Path(production['settings']['model_source'])
    require(not base.is_relative_to(args.model_dir.resolve()) and
            not base.is_relative_to(ROOT/'web') and
            not base.is_relative_to(Path(production['settings']['runtime'])), 'pasta local deve ser isolada')
    base.mkdir(parents=True, exist_ok=True)
    config_path = base/'variant.json'
    if config_path.exists():
        config = read_json(config_path)
        verify_model(Path(config['model_source']))
        require(config['extension_sha256'] == digest((EXPERIMENT/'extensao.R').read_bytes()),
                'extensão mudou; prepare outra --base')
        require(config['source'] == str(args.source.resolve()), 'origem mudou; use outra --base')
        return config
    verify_model(source)
    destination = base/'model-source'
    freeze_model(source, destination)
    shutil.copy2(EXPERIMENT/'extensao.R', destination/'comparecimento_uf.R')
    with (destination/'previsao_execucao.R').open('a') as stream:
        stream.write('\nsource(file.path(.previsao_dir, "comparecimento_uf.R"), encoding="UTF-8")\n')
    manifest = read_json(destination/'source-manifest.json')
    manifest.update(derived_from_manifest_sha256=digest((source/'source-manifest.json').read_bytes()),
                    variant='turnout_uf', files={name:digest(raw) for name,raw in source_files(destination).items()})
    atomic_write(destination/'source-manifest.json', manifest)
    verify_model(destination)
    inputs = base/'inputs'
    inputs.mkdir(exist_ok=True)
    config = dict(base=str(base), model_source=str(destination),
        source=str(args.source.resolve()),
        historical_fit=str(args.model_dir/'output/comparecimento_preditor_20261020/final/ambos/posterior.rds'),
        t1_file=str((args.model_dir/'../data/eleicoes_2022_2026/raw/section_votes_2026_T1_bu.parquet').resolve()),
        variant_fit=str(inputs/'fit-ambos.rds'), variant_initial=str(base/'initial-state'),
        extension_sha256=digest((EXPERIMENT/'extensao.R').read_bytes()),
        production_initial=str(production['settings']['initial_state']))
    atomic_write(config_path, config)
    return config


def initialize(args, config):
    if (args.base/'initial-validation.json').exists():
        return
    with (args.base/'preparation.log').open('ab') as log:
        subprocess.run([args.rscript, '--vanilla', str(EXPERIMENT/'inicializar.R'),
                        str(args.base/'variant.json')], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                       env={**os.environ,'LANG':'en_US.UTF-8','LC_ALL':'en_US.UTF-8'}, check=True)


class TurnoutPipeline(Pipeline):
    def settings(self):
        return {**super().settings(), 'repo':str(ROOT),
                'variant_initial':self.args.variant['variant_initial'],
                'variant_fit':self.args.variant['variant_fit'],
                'country_map':str(EXPERIMENT/'paises.csv')}

    def r(self, command):
        verify_model(self.runtime/'model-source')
        with (self.runtime/'pipeline.log').open('ab') as log:
            log.write(f'\n[{datetime.now(timezone.utc).isoformat()}] {command}\n'.encode())
            log.flush()
            self.child = subprocess.Popen([self.args.rscript, '--vanilla', str(EXPERIMENT/'pipeline.R'),
                command, str(self.runtime/'settings.json')], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                env={**os.environ,'LANG':'en_US.UTF-8','LC_ALL':'en_US.UTF-8'})
            code = self.child.wait()
            self.child = None
        if code:
            raise RuntimeError(f'executor local falhou ({command}, código {code}); consulte pipeline.log')

    def update(self):
        super().update()
        report = read_json(self.runtime/'local-report.json')
        require(report['kind'] == 'pet_local_turnout_uf' and report['coefficients'] == 86,
                'relatório não corresponde à variante por UF')
        require(report['synthetic'] == (self.args.mode == 'demo'), 'origem fictícia/real incompatível')
        for forecast in report['national'].values():
            require(0 <= forecast['lower'] <= forecast['share'] <= forecast['upper'] <= 100,
                    'projeção ou faixa nacional inválida')
        production = read_json(ROOT/'local/cloudflare-production/current.json')
        public = read_json(Path(production['settings']['runtime'])/'public/latest.json')
        report['public_same_source'] = report['source_snapshot_id'] == public['forecast']['source_snapshot_id']
        report['public_national'] = ({'learning':public['forecast']['share_a'],
            'historical':public['forecast_2022']['share_a']} if report['public_same_source'] else None)
        destination = self.args.base/'latest-report.json'
        previous = read_json(destination) if destination.exists() else None
        atomic_write(destination, report)
        if previous is None or previous['checkpoint_id'] != report['checkpoint_id']:
            with (self.args.base/'history.jsonl').open('a') as stream:
                stream.write(json.dumps(report,ensure_ascii=False,allow_nan=False)+'\n')
        self.report = report
        write_markdown(self.args.base/'relatorio.md', report)
        atomic_write(self.args.base/'status.json', self.status())

    def status(self):
        return {**super().status(), 'variant':'turnout_uf', 'coefficients':86,
                'checked_at_utc':getattr(self,'report',{}).get('checked_at_utc')}


def write_markdown(path, report):
    n = report['national']
    lines = ['# Projeções locais: comparecimento por UF', '',
        f"Boletins incorporados: {report['observed_sections']} de {report['sections']} seções.",
        f"Previsão calculada em: {report['generated_at_utc']}. Consulta: {report['checked_at_utc']}.", '',
        '| Cenário | Lula (% válidos) | Faixa de 95% |', '|---|---:|---:|']
    for key,label in [('learning','Com aprendizado'),('historical','Relação de 2022')]:
        f = n[key]
        lines.append(f"| {label} | {f['share']:.3f}% | {f['lower']:.3f}% a {f['upper']:.3f}% |")
    lines += ['', '## UFs', '', '| UF | BUs | Com aprendizado | Relação de 2022 |', '|---|---:|---:|---:|']
    for row in report['ufs']:
        lines.append(f"| {row['uf']} | {row['observed']} | {row['learning']:.3f}% | {row['historical']:.3f}% |")
    lines += ['', '## Primeiros países do exterior', '', '| País | BUs | Com aprendizado | Relação de 2022 |', '|---|---:|---:|---:|']
    for row in report['countries']:
        lines.append(f"| {row['pais']} | {row['apuradas']} | {row['learning']:.3f}% | {row['historical']:.3f}% |")
    temporary = path.with_suffix('.tmp')
    temporary.write_text('\n'.join(lines)+'\n')
    temporary.replace(path)


class TurnoutHandler(Handler):
    def do_GET(self):
        if not self.trusted_local_request():
            return self.json({'error':'Origem local inválida'},403)
        if urlsplit(self.path).path == '/api/report':
            value = getattr(self.server.pipeline,'report',None)
            return self.json(value) if value else self.json({'error':'Aguardando cálculo'},503)
        return super().do_GET()

    def do_POST(self):
        if not self.trusted_local_request():
            return self.json({'error':'Origem local inválida'},403)
        return self.json({'error':'Painel somente de leitura'},405)


def install_agent(args):
    generated = args.base/'services'
    generated.mkdir(exist_ok=True)
    config = dict(Label=LABEL, ProgramArguments=[sys.executable,'-u',str(Path(__file__).resolve()),
        '--base',str(args.base),'--model-dir',str(args.model_dir),'--rscript',args.rscript,
        '--source',str(args.source),'--draws',str(args.draws),'--seed',str(args.seed),
        '--interval',str(args.interval or 60),'--port',str(args.port)], WorkingDirectory=str(ROOT), RunAtLoad=True,
        KeepAlive={'SuccessfulExit':False},ThrottleInterval=20,AbandonProcessGroup=False,
        EnvironmentVariables={'PATH':os.environ.get('PATH','/usr/bin:/bin'),
                              'LANG':'en_US.UTF-8','LC_ALL':'en_US.UTF-8'},
        StandardOutPath=str(args.base/'service.out.log'), StandardErrorPath=str(args.base/'service.err.log'))
    source = generated/(LABEL+'.plist')
    source.write_bytes(plistlib.dumps(config))
    subprocess.run(['/usr/bin/plutil','-lint',str(source)],check=True)
    destination = Path.home()/'Library/LaunchAgents'/source.name
    destination.parent.mkdir(parents=True,exist_ok=True)
    require(not destination.exists(), 'serviço local já instalado; não sobrescrever')
    shutil.copy2(source,destination)
    destination.chmod(0o644)
    subprocess.run(['/bin/launchctl','bootstrap',f'gui/{os.getuid()}',str(destination)],check=True)


def main():
    p = parser()
    p.description = __doc__
    p.set_defaults(mode='tse',port=4174,name_a='Lula',name_b='Flávio Bolsonaro')
    p.add_argument('--base',type=Path,default=ROOT/'local/comparecimento-uf')
    p.add_argument('--prepare-only',action='store_true')
    p.add_argument('--install-agent',action='store_true')
    args = p.parse_args()
    args.base = args.base.resolve(); args.model_dir = args.model_dir.resolve()
    args.source = (args.source or args.model_dir/'data/live/tse_export').resolve()
    args.variant = prepare_variant(args)
    initialize(args,args.variant)
    args.model_code = Path(args.variant['model_source'])
    args.initial_state = args.initial_state or Path(args.variant['variant_initial'])
    args.runtime = args.runtime or args.base/'live'
    require(args.interval is None or args.interval >= 60, 'consulta de produção a cada pelo menos 60 segundos')
    require(args.draws >= 100 and 1 <= args.sections_per_uf <= 1000, 'sorteios ou seções inválidos')
    if args.prepare_only:
        print(json.dumps(read_json(args.base/'initial-validation.json'),ensure_ascii=False)); return
    if args.install_agent:
        require(args.mode == 'tse', 'serviço persistente exige dados reais')
        install_agent(args); return
    with runtime_lock(args.runtime.resolve()):
        pipeline = TurnoutPipeline(args)
        try:
            pipeline.prepare()
            if args.once:
                print(json.dumps(pipeline.report['national'],ensure_ascii=False)); return
            pipeline.start()
            window = read_json(ROOT/'deployment/collector-2026.json')
            end = datetime.fromisoformat(window['end'])
            server = ThreadingHTTPServer(('127.0.0.1',args.port),partial(TurnoutHandler,directory=str(EXPERIMENT/'web')))
            server.pipeline = pipeline; server.timeout = 1
            try:
                print(f'Projeções locais em http://127.0.0.1:{args.port}/',flush=True)
                while datetime.now(timezone.utc) < end:
                    server.handle_request()
            finally:
                server.server_close()
        finally:
            pipeline.close()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('Execução local encerrada; último relatório preservado.')
