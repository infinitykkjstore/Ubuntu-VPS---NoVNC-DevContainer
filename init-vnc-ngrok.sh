#!/usr/bin/env bash
# setup_vnc_cloudflared.sh
# Executa passos sequenciais. Apenas vncserver e websockify ficam em 2º plano.
set -euo pipefail

# variável configurável
VNC_PASSWORD="12345678"
VNC_GEOMETRY="1024x768"
WEB_PORT=6080
WAIT_RETRIES=60   # quantas vezes checar se o vncserver iniciou (1s por retry)
LOG=/tmp/vncserver_start.log

export HOME="${HOME:-/root}"
mkdir -p "$HOME/.vnc"

echo "1) apt update"
sudo apt update

echo "2) instalando xfce4"
sudo apt install xfce4 -y

echo "3) instalando xfce4-goodies"
sudo apt install xfce4-goodies -y

echo "4) instalando tigervnc-standalone-server"
sudo apt install tigervnc-standalone-server -y

echo "5) instalando dbus-x11"
sudo apt install dbus-x11 -y

echo "6) criando senha VNC"
# cria senha no formato que o vncpasswd espera
printf '%s\n' "$VNC_PASSWORD" | vncpasswd -f > "$HOME/.vnc/passwd"
chmod 600 "$HOME/.vnc/passwd"

echo "7) criando config VNC"
cat > "$HOME/.vnc/config" <<EOF
geometry=${VNC_GEOMETRY}
localhost=no
EOF

echo "8) criando xstartup e corrigindo xrdb"
cat > "$HOME/.vnc/xstartup" <<'EOF'
tigervncserver -xstartup startxfce4
EOF
chmod +x "$HOME/.vnc/xstartup"
touch ~/.Xresources
chmod +x ~/.Xresources

echo "8-1) corrigindo session"
cat > "/etc/X11/Xtigervnc-session" <<'EOF'
tigervncserver -xstartup startxfce4
EOF
chmod +x /etc/X11/Xtigervnc-session
touch /etc/X11/Xtigervnc-session
chmod +x /etc/X11/Xtigervnc-session

echo "9) iniciando vncserver :0"
vncserver -kill :0 &>/dev/null || true
vncserver :0 &>/dev/null

echo "Aguardando vncserver aparecer (até ${WAIT_RETRIES}s)..."
retries=0
success=0

while ((retries < WAIT_RETRIES)); do
  # 1) verifica vncserver -list por qualquer display :1..:5
  vlist=$(vncserver -list 2>/dev/null || true)
  disp=$(echo "$vlist" | grep -oE ':[1-5]\b' | head -n1 || true)
  if [[ -n "$disp" ]]; then
    disp_num=${disp#:}
    vnc_tcp_port=$((5900 + disp_num))
    echo "vncserver detectado via 'vncserver -list': $disp -> porta $vnc_tcp_port"
    success=1
    break
  fi

  # 2) verifica se qualquer porta 5901..5905 está em LISTEN
  port_found=$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -oE ':(590[1-5])$' | tr -d ':' | head -n1 || true)
  if [[ -n "$port_found" ]]; then
    vnc_tcp_port=$port_found
    disp_num=$((vnc_tcp_port - 5900))
    echo "Porta detectada em LISTEN: $vnc_tcp_port -> display :$disp_num"
    success=1
    break
  fi

  sleep 1
  retries=$((retries+1))
done

if (( success == 0 )); then
  echo "Timeout aguardando vncserver. Veja $LOG"
  exit 1
fi

echo "Display detectado: :$disp_num -> porta TCP: $vnc_tcp_port"

# prepara repositório da Mozilla (passos sequenciais)
echo "Criando /etc/apt/keyrings e adicionando chave mozilla"
sudo install -d -m 0755 /etc/apt/keyrings
wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- | sudo tee /etc/apt/keyrings/packages.mozilla.org.asc >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" | sudo tee /etc/apt/sources.list.d/mozilla.list >/dev/null
cat <<'EOF' | sudo tee /etc/apt/preferences.d/mozilla >/dev/null
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
Package: firefox*
Pin: release o=Ubuntu
Pin-Priority: -1
EOF

echo "Atualizando apt novamente"
sudo apt update

echo "Removendo firefox (se presente) e instalando firefox"
sudo apt remove -y firefox || true
sudo apt install -y firefox

echo "Configurando repositório do cloudflared"
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null

echo "Instalando cloudflared"
sudo apt-get update
sudo apt-get install -y cloudflared

echo "Instalando noVNC / websockify"
sudo apt install -y novnc websockify python3-websockify

# inicia websockify apontando para a porta detectada do VNC
echo "Iniciando websockify: porta web $WEB_PORT -> localhost:${vnc_tcp_port}"
# inicia em background e registra log
/usr/bin/websockify --web=/usr/share/novnc/ "${WEB_PORT}" "localhost:${vnc_tcp_port}" >/tmp/websockify.log 2>&1 &

WEBSOCKIFY_PID=$!

# aguarda até que a porta WEB_PORT esteja escutando (ou até timeout)
echo "Aguardando websockify ficar disponível na porta $WEB_PORT..."
retries=0
while true; do
  # checa se processo websockify ainda existe
  if ! kill -0 "$WEBSOCKIFY_PID" 2>/dev/null; then
    echo "Erro: websockify terminou inesperadamente. Veja /tmp/websockify.log"
    exit 1
  fi
  # checa se a porta está escutando (usa ss ou netstat)
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn | awk '{print $4}' | grep -qE "[:.]${WEB_PORT}\$"; then
      break
    fi
  else
    if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${WEB_PORT}\$"; then
      break
    fi
  fi
  retries=$((retries+1))
  if [ "$retries" -ge "$WAIT_RETRIES" ]; then
    echo "Timeout aguardando websockify. Veja /tmp/websockify.log"
    exit 1
  fi
  sleep 1
done

echo "websockify iniciado com PID $WEBSOCKIFY_PID (log em /tmp/websockify.log)."

echo "Pronto — agora executando cloudflared em primeiro plano (última etapa)."
# Executa em primeiro plano e substitui o shell (útil para container/serviço)
exec cloudflared tunnel --url "localhost:${WEB_PORT}/"
