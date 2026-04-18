# 🚀 Setup automático XFCE4 + VNC + noVNC + Cloudflared em DevContainer

O (`install.sh`) automatiza a instalação e configuração de um ambiente gráfico remoto dentro de um DevContainer (como GitHub Codespaces), incluindo:

- 🖥️ XFCE4
- 🔐 TigerVNC (servidor VNC)
- 🌐 noVNC + websockify (acesso via navegador)
- ☁️ Cloudflared (túnel para expor NoVNC)

---


## ⚙️ Configurações padrão

Você pode ajustar no início do script:

```bash
VNC_PASSWORD="12345678"   # senha de acesso
VNC_GEOMETRY="1024x768"  # resolução da tela
WEB_PORT=6080            # porta do noVNC
WAIT_RETRIES=60          # tempo máximo de espera (segundos)
