# Remote Jupyter GPU Launcher

One-click launcher that sets up JupyterLab with GPU (CUDA) support on a Windows 11 PC and exposes it via Cloudflare Tunnel for remote access.

## Features

- **One-click setup**: Auto-installs Python, PyTorch (CUDA), JupyterLab, and cloudflared via winget
- **Tunnel auto-connect**: Generates a public URL through Cloudflare Quick Tunnel or ngrok
- **QR code & short URL**: Scan from mobile to connect instantly
- **Stable Diffusion WebUI**: Gradio-based image generation UI included
- **GPU test notebooks**: Ready-to-run CUDA connectivity and performance benchmarks

## Files

| File | Description |
|------|-------------|
| `remote-jupyter-win.cmd` | Main launcher (double-click to run) |
| `remote-jupyter-win.ps1` | PowerShell version of the launcher |
| `launcher_helper.py` | Creates venv, starts Jupyter, connects tunnel |
| `stop-remote-jupyter-win.cmd` | Stops Jupyter & tunnel |
| `stop-remote-jupyter-win.ps1` | PowerShell version of the stopper |
| `sd_webui.py` | Stable Diffusion Gradio WebUI |
| `GPU Connect Test.ipynb` | GPU connectivity & performance test notebook |
| `Stable Diffusion.ipynb` | Stable Diffusion image generation notebook |

## Usage

1. Copy this folder to a Windows 11 PC with an NVIDIA GPU
2. Double-click `remote-jupyter-win.cmd`
3. Wait for the automatic setup to complete
4. A public URL will be displayed — open it in any browser
5. Run `stop-remote-jupyter-win.cmd` when done

## Requirements

- Windows 11 (with winget)
- NVIDIA GPU with CUDA support
- Internet connection

## Environment Variables (optional)

- `TORCH_CUDA_CHANNEL`: PyTorch CUDA version (default: `cu128`, options: `cu126`, `cu130`)
- `NGROK_AUTHTOKEN`: Auth token when using ngrok as tunnel

## License

MIT
