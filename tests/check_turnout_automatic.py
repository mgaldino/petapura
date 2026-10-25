"""Verifica a variante por HTTP até 100%, sem comandos de avanço por POST."""
import argparse
import csv
from functools import partial
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from urllib.request import urlopen

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from contract import atomic_write,read_json
from run_local import parser
from run_turnout_local import EXPERIMENT,TurnoutHandler
from replay_turnout import VariantTestPipeline


def serve(runtime):
    args=parser().parse_args(['--runtime',str(runtime),'--interval','1','--rscript','/usr/local/bin/Rscript'])
    pipeline=VariantTestPipeline(args)
    try:
        pipeline.prepare()
        server=ThreadingHTTPServer(('127.0.0.1',0),partial(TurnoutHandler,directory=str(EXPERIMENT/'web')))
        server.pipeline=pipeline
        pipeline.start()
        print(f'Local: http://127.0.0.1:{server.server_port}/',flush=True)
        try:server.serve_forever(poll_interval=.1)
        finally:server.server_close()
    except KeyboardInterrupt:pass
    finally:pipeline.close()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--serve',action='store_true')
    p.add_argument('--runtime',type=Path,default=ROOT/'local/validacao-uf-http-20261024')
    args=p.parse_args();args.runtime=args.runtime.resolve()
    if args.serve:return serve(args.runtime)
    assert not args.runtime.exists(),'Use outra pasta de teste'
    args.runtime.mkdir(parents=True)
    started=time.monotonic();stages={}
    with (args.runtime/'server.log').open('w') as log:
        child=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'--serve','--runtime',str(args.runtime)],
            cwd=ROOT,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
    try:
        while time.monotonic()-started<180:
            assert child.poll() is None,(args.runtime/'server.log').read_text()[-3000:]
            found=re.search(r'Local: (http://127\.0\.0\.1:\d+)/',(args.runtime/'server.log').read_text())
            if not found:time.sleep(.1);continue
            url=found[1]
            with urlopen(url+'/api/status',timeout=10) as response:status=json.load(response)
            with urlopen(url+'/api/report',timeout=10) as response:report=json.load(response)
            assert status['error'] is None,status['error']
            assert report['synthetic'] and report['coefficients']==86
            stages[report['observed_sections']]=report['checkpoint_id']
            if status['complete'] and not status['busy']:break
            time.sleep(.15)
        else:raise AssertionError('O fluxo HTTP não chegou a 100%')
        assert len(stages)==status['stages']==24
        pointer=read_json(args.runtime/'current.json');run=Path(pointer['settings']['runtime'])
        truth=list(csv.DictReader((run/'fixture/truth.csv').open()))
        a=sum(int(row['votos_a']) for row in truth);b=sum(int(row['votos_b']) for row in truth)
        for forecast in report['national'].values():
            assert abs(forecast['share']-100*a/(a+b))<1e-9
            assert abs(forecast['upper']-forecast['lower'])<1e-9
        result=dict(passed=True,stages=len(stages),coefficients=86,automatic_without_posts=True,
                    synthetic_test_only=True,final_share=100*a/(a+b),seconds=round(time.monotonic()-started,3))
        atomic_write(args.runtime/'verification.json',result)
        print(json.dumps(result,ensure_ascii=False))
    finally:
        child.send_signal(signal.SIGINT)
        try:child.wait(timeout=15)
        except subprocess.TimeoutExpired:child.kill();child.wait()


if __name__=='__main__':main()
