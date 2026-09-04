"使驾独立重启助手。"
from __future__ import annotations
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import Request,urlopen
DETACHED_PROCESS=0x00000008
CREATE_NEW_PROCESS_GROUP=0x00000200
CREATE_NO_WINDOW=0x08000000
def log(message: str) -> None:
    try:
        directory=Path(os.environ.get('LOCALAPPDATA',Path.home()))/'PowerUI'/'WorkflowManager'/'logs'
        directory.mkdir(parents=True,exist_ok=True)
        with (directory/'restartShiJia.log').open('a',encoding='utf-8') as stream:
            stream.write(time.strftime('%Y-%m-%d %H:%M:%S ')+message+chr(10))
    except Exception:
        pass
def find_application_root() -> Path:
    script_dir=Path(__file__).resolve().parent
    if (script_dir/'WorkflowManager.exe').exists():
        return script_dir
    dist_dir=script_dir/'dist'
    if (dist_dir/'WorkflowManager.exe').exists():
        return dist_dir
    return script_dir
def read_web_port() -> int:
    try:
        settings=Path(os.environ.get('LOCALAPPDATA',Path.home()))/'PowerUI'/'WorkflowManager'/'settings.json'
        data=json.loads(settings.read_text(encoding='utf-8-sig'))
        if bool(data.get('WebEnabled')):
            port=int(data.get('WebPort',5170))
            if 1<=port<=65535:
                return port
    except Exception:
        pass
    return 5170
def request_graceful_restart(port: int=5169) -> None:
    try:
        request=Request(f'http://127.0.0.1:{port}/api/system/restart',method='POST',headers={'Connection':'close'})
        with urlopen(request,timeout=3) as response:
            response.read()
        log(f'已请求使驾退出，API端口：{port}')
    except (OSError,URLError) as exc:
        log(f'请求使驾退出失败，将继续等待：{exc}')
def is_port_available(port: int) -> bool:
    if port<=0:
        return True
    sock=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
    try:
        sock.bind(('127.0.0.1',port))
        return True
    except OSError:
        return False
    finally:
        sock.close()
def target_process_running(target: Path) -> bool:
    try:
        result=subprocess.run(['tasklist.exe','/FI',f'IMAGENAME eq {target.name}','/FO','CSV','/NH'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,stdin=subprocess.DEVNULL,creationflags=CREATE_NO_WINDOW,timeout=3,check=False)
        output=result.stdout.decode(errors='replace').lower()
        return target.name.lower() in output and 'no tasks' not in output
    except Exception:
        return False
def wait_for_old_instance(target: Path,ports: list[int],timeout: float=35.0) -> None:
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if not target_process_running(target) and all(is_port_available(port) for port in ports if port>0):
            return
        time.sleep(0.2)
    log('等待旧实例或端口释放超时，继续尝试替换文件。')
def apply_next_binary(target: Path,next_target: Path) -> None:
    if not next_target.exists():
        log('没有发现待应用的 WorkflowManager.next.exe，保留当前版本。')
        return
    last_error=None
    for _ in range(100):
        try:
            os.replace(str(next_target),str(target))
            log(f'已应用新版：{next_target}')
            return
        except OSError as exc:
            last_error=exc
            time.sleep(0.25)
    raise RuntimeError(f'无法替换使驾程序：{last_error}')
def launch_target(target: Path,root: Path) -> None:
    if not target.exists():
        raise FileNotFoundError(str(target))
    subprocess.Popen([str(target)],cwd=str(root),stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,close_fds=True,creationflags=DETACHED_PROCESS|CREATE_NEW_PROCESS_GROUP)
    log(f'已启动使驾：{target}')
def run_worker() -> int:
    root=find_application_root()
    target=root/'WorkflowManager.exe'
    next_target=root/'WorkflowManager.next.exe'
    try:
        request_graceful_restart()
        wait_for_old_instance(target,[5169,read_web_port()])
        apply_next_binary(target,next_target)
        launch_target(target,root)
        return 0
    except Exception as exc:
        log(f'重启失败：{exc}')
        return 1
def main() -> int:
    if '--worker' not in sys.argv[1:]:
        worker=[sys.executable,str(Path(__file__).resolve()),'--worker']
        try:
            subprocess.Popen(worker,cwd=str(Path(__file__).resolve().parent),stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,close_fds=True,creationflags=DETACHED_PROCESS|CREATE_NEW_PROCESS_GROUP|CREATE_NO_WINDOW)
            print('独立 Python 重启助手已启动。')
            return 0
        except Exception as exc:
            log(f'无法启动独立 Python 重启助手：{exc}')
            print(f'无法启动独立 Python 重启助手：{exc}',file=sys.stderr)
            return 1
    return run_worker()
if __name__=='__main__':
    raise SystemExit(main())
