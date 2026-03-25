import json, logging, os, re, secrets, socket, subprocess, sys, time, urllib.request
from pathlib import Path
from shutil import which

# USB 로그: 이 스크립트가 있는 폴더(USB)에 로그 저장
_script_dir = Path(__file__).resolve().parent
_usb_log = _script_dir / "launcher.log"
logging.basicConfig(
    filename=str(_usb_log),
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)s %(message)s",
    encoding="utf-8",
)
log = logging.getLogger("launcher")
log.info("=== Launcher started ===")

workdir = Path(os.environ["WORKDIR"])
state_dir = Path(os.environ["STATE_DIR"])
venv_dir = Path(os.environ["VENV_DIR"])
torch_channel = os.environ.get("TORCH_CUDA_CHANNEL", "cu128")

state_dir.mkdir(parents=True, exist_ok=True)
workdir.mkdir(parents=True, exist_ok=True)

# 모델 저장 폴더 생성
models_dir = workdir / "models"
models_dir.mkdir(exist_ok=True)
(models_dir / "stable-diffusion").mkdir(exist_ok=True)
(models_dir / "lora").mkdir(exist_ok=True)
(models_dir / "vae").mkdir(exist_ok=True)
log.info("Models directory: %s", models_dir)

jupyter_log = state_dir / "jupyter.log"
tunnel_log = state_dir / "tunnel.log"
tunnel_err_log = state_dir / "tunnel.err.log"
jupyter_pid = state_dir / "jupyter.pid"
tunnel_pid = state_dir / "tunnel.pid"
token_file = state_dir / "token.txt"


def run(cmd):
    print(">", " ".join(cmd))
    log.info("run: %s", " ".join(cmd))
    subprocess.check_call(cmd)


def stop_from_file(path):
    if not path.exists():
        return
    try:
        pid = int(path.read_text().strip())
    except Exception:
        path.unlink(missing_ok=True)
        return
    subprocess.run(
        ["taskkill", "/PID", str(pid), "/F"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    path.unlink(missing_ok=True)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_http(url, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=3) as resp:
                if resp.status < 500:
                    return True
        except Exception:
            time.sleep(1)
    return False


def read_trycloudflare(log_path, timeout=45):
    pat = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")
    deadline = time.time() + timeout
    while time.time() < deadline:
        text = log_path.read_text(errors="ignore") if log_path.exists() else ""
        m = pat.search(text)
        if m:
            return m.group(0)
        time.sleep(1)
    return None


def read_ngrok(timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(
                "http://127.0.0.1:4040/api/tunnels", timeout=3
            ) as resp:
                data = json.load(resp)
            for tunnel in data.get("tunnels", []):
                url = tunnel.get("public_url", "")
                if url.startswith("https://"):
                    return url
        except Exception:
            time.sleep(1)
    return None


# --- main ---
stop_from_file(jupyter_pid)
stop_from_file(tunnel_pid)

if not (venv_dir / "Scripts" / "python.exe").exists():
    run([sys.executable, "-m", "venv", str(venv_dir)])

py = str(venv_dir / "Scripts" / "python.exe")
run([py, "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"])
run([py, "-m", "pip", "install", "--upgrade", "jupyterlab", "notebook", "ipykernel"])
run([py, "-m", "pip", "install", "--upgrade", "torch", "torchvision", "torchaudio",
     "--index-url", f"https://download.pytorch.org/whl/{torch_channel}"])
run([py, "-m", "ipykernel", "install", "--user", "--name", "remote-gpu",
     "--display-name", "Python (.venv-gpu)"])
run([py, "-c",
     "import torch; print('torch', torch.__version__); "
     "print('cuda', torch.cuda.is_available()); "
     "print('devices', torch.cuda.device_count())"])

port = free_port()
token = secrets.token_urlsafe(24)
token_file.write_text(token)
local_url = f"http://127.0.0.1:{port}/lab?token={token}"

jout = open(jupyter_log, "w", encoding="utf-8")
jerr = open(state_dir / "jupyter.err.log", "w", encoding="utf-8")

# Jupyter 환경에 모델 경로 전달
jupyter_env = os.environ.copy()
jupyter_env["MODELS_DIR"] = str(models_dir)
jupyter_env["SD_MODELS_DIR"] = str(models_dir / "stable-diffusion")
jupyter_env["LORA_MODELS_DIR"] = str(models_dir / "lora")
jupyter_env["VAE_MODELS_DIR"] = str(models_dir / "vae")
# HuggingFace 캐시도 models 폴더로 지정
jupyter_env["HF_HOME"] = str(models_dir / ".hf_cache")

jproc = subprocess.Popen(
    [py, "-m", "jupyterlab", "--no-browser",
     "--ServerApp.ip=127.0.0.1", f"--ServerApp.port={port}",
     "--ServerApp.port_retries=0",
     f"--ServerApp.token={token}", f"--IdentityProvider.token={token}",
     "--ServerApp.allow_remote_access=True",
     "--ServerApp.allow_origin=*",
     "--ServerApp.disable_check_xsrf=True"],
    cwd=str(workdir), stdout=jout, stderr=jerr, env=jupyter_env,
)
jupyter_pid.write_text(str(jproc.pid))

log.info("Waiting for Jupyter at %s", local_url)
if not wait_http(local_url):
    log.error("Jupyter failed to start")
    print("Jupyter failed to start. Check", jupyter_log)
    sys.exit(1)
log.info("Jupyter is ready")

public_url = None
tout = open(tunnel_log, "w", encoding="utf-8")
terr = open(tunnel_err_log, "w", encoding="utf-8")

if which("cloudflared"):
    log.info("Starting cloudflared tunnel on port %d", port)
    tproc = subprocess.Popen(
        ["cloudflared", "tunnel", "--url", f"http://127.0.0.1:{port}"],
        stdout=tout, stderr=subprocess.STDOUT,
    )
    tunnel_pid.write_text(str(tproc.pid))
    public_url = read_trycloudflare(tunnel_log)
    log.info("cloudflared result: %s", public_url)
    # 터널 로그 내용도 기록
    try:
        log.info("tunnel.log contents:\n%s", tunnel_log.read_text(errors="ignore"))
    except Exception:
        pass
elif which("ngrok"):
    authtoken = os.environ.get("NGROK_AUTHTOKEN")
    if authtoken:
        subprocess.run(["ngrok", "config", "add-authtoken", authtoken], check=False)
    tproc = subprocess.Popen(
        ["ngrok", "http", f"127.0.0.1:{port}", "--log=stdout"],
        stdout=tout, stderr=terr,
    )
    tunnel_pid.write_text(str(tproc.pid))
    public_url = read_ngrok()

def shorten_url(long_url):
    encoded = urllib.request.quote(long_url, safe="")
    ua = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
    results = []

    # clck.ru (GET)
    try:
        req = urllib.request.Request(f"https://clck.ru/--?url={encoded}", headers=ua)
        with urllib.request.urlopen(req, timeout=8) as resp:
            result = resp.read().decode().strip()
            if result.startswith("http"):
                log.info("shortener clck.ru: %s", result)
                results.append(("clck.ru", result))
    except Exception as e:
        log.warning("shortener clck.ru failed: %s", e)

    # lrl.kr (POST JSON, no API key)
    try:
        body = json.dumps({"url": long_url}).encode()
        req = urllib.request.Request(
            "https://lrl.kr/api/short",
            data=body,
            headers={**ua, "Content-Type": "application/json; charset=UTF-8"},
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read().decode())
            result = data.get("result", "")
            if result.startswith("http"):
                log.info("shortener lrl.kr: %s", result)
                results.append(("lrl.kr", result))
            elif result:
                short = f"https://lrl.kr/{result}"
                log.info("shortener lrl.kr: %s", short)
                results.append(("lrl.kr", short))
    except Exception as e:
        log.warning("shortener lrl.kr failed: %s", e)

    return results


def copy_to_clipboard(text):
    try:
        p = subprocess.Popen(["clip"], stdin=subprocess.PIPE)
        p.communicate(text.encode("utf-8"))
    except Exception:
        pass


def print_qr(text):
    try:
        import qrcode
    except ImportError:
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "--quiet", "qrcode"],
        )
        import qrcode
    qr = qrcode.QRCode(box_size=1, border=1)
    qr.add_data(text)
    qr.make(fit=True)
    qr.print_ascii(invert=True)


full_public_url = f"{public_url}?token={token}" if public_url else None
log.info("full_public_url: %s", full_public_url)

print()
print("=" * 60)
print("  JupyterLab is running.")
print("=" * 60)
print()
print("Local URL :", local_url)
if full_public_url:
    print("Public URL:", full_public_url)
    shorts = shorten_url(full_public_url)
    if shorts:
        for name, url in shorts:
            print(f"Short URL  ({name}): {url}")
        best = min(shorts, key=lambda x: len(x[1]))[1]
        copy_to_clipboard(best)
        print("  (clipboard copied!)")
        print()
        print("Scan QR code to open:")
        print_qr(best)
    else:
        copy_to_clipboard(full_public_url)
        print("  (clipboard copied!)")
        print()
        print("Scan QR code to open:")
        print_qr(full_public_url)
else:
    print("Public URL: unavailable")
    print("Tunnel log:", tunnel_log)
print()
print("Work dir  :", workdir)
print("Models dir:", models_dir)
print("Venv path :", venv_dir)
print("Jupyter log:", jupyter_log)
