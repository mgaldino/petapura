"""Executa o modelo R e publica os dois cenários no KV, sem iniciar outro coletor."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from contract import atomic_write, require, validate
from run_local import Pipeline, ROOT, parser, runtime_lock


def upload(snapshot, runtime, config, wrangler):
    validate(snapshot, config)
    require(snapshot['mode'] == 'live' and snapshot.get('forecast_2022') is not None,
            'produção exige os dois cenários reais')
    path = runtime / 'cloudflare-upload.json'
    atomic_write(path, snapshot)
    subprocess.run([wrangler, 'kv', 'key', 'put', 'latest', '--binding', 'SNAPSHOTS',
                    '--path', str(path), '--remote', '--config', str(ROOT / 'wrangler.jsonc')],
                   cwd=ROOT, check=True, timeout=120)


def main():
    p = parser()
    p.description = __doc__
    p.set_defaults(mode='tse', name_a='Lula', name_b='Flávio Bolsonaro')
    p.add_argument('--wrangler', default=os.environ.get('PET_WRANGLER') or shutil.which('wrangler'))
    args = p.parse_args()
    require(args.mode == 'tse', 'publicação remota recusa simulação')
    require(args.wrangler is not None, 'informe --wrangler ou PET_WRANGLER')
    require(args.draws >= 100, 'pelo menos 100 sorteios por cenário')
    require(args.interval is None or args.interval >= 60, 'publicação a cada pelo menos 60 segundos')
    args.runtime = args.runtime or ROOT / 'local/cloudflare-production'
    args.source = args.source or args.model_dir / 'data/live/tse_export'
    args.initial_state = args.initial_state or args.model_dir / 'data/processed/estado_inicial_v2'
    pipeline = Pipeline(args)
    last_sent = None
    with runtime_lock(args.runtime.resolve()):
        try:
            pipeline.prepare()
            while True:
                try:
                    snapshot = pipeline.latest
                    if snapshot['snapshot_id'] != last_sent:
                        upload(snapshot, pipeline.runtime, pipeline.config, args.wrangler)
                        last_sent = snapshot['snapshot_id']
                        print(json.dumps({'published':last_sent,'generated_at':snapshot['generated_at']},ensure_ascii=False),flush=True)
                    if args.once:
                        break
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    print(f'Publicação não concluída; último resultado remoto preservado: {error}',flush=True)
                    if args.once:
                        raise
                time.sleep(pipeline.interval)
                try:
                    pipeline.update()
                    pipeline.remember()
                except (OSError, ValueError, RuntimeError) as error:
                    print(f'Atualização não concluída; nova tentativa no próximo ciclo: {error}',flush=True)
        finally:
            pipeline.close()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\nPublicador encerrado; último resultado continua no Workers.')
