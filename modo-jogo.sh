#!/usr/bin/env bash
# Modo Jogo (Linux Mint / Cinnamon)
# Reduz o que pesa, ativa o GameMode e abre a Steam.
# Quando a Steam fecha, tudo volta ao normal.
#
# Requer: sudo apt install gamemode

notify() {
  command -v notify-send >/dev/null && notify-send -i applications-games "Modo Jogo" "$1"
}

# Se o Modo Jogo ja estiver ativo, nao roda de novo
if pgrep -f "modo-jogo" | grep -qv "^$$\$"; then
  notify "O Modo Jogo ja esta ativo."
  exit 0
fi

# Escolhe como abrir a Steam (com ou sem GameMode)
if command -v gamemoderun >/dev/null; then
  STEAM_CMD="gamemoderun steam"
  AVISO="Modo Jogo ativado: desempenho maximo."
else
  STEAM_CMD="steam"
  AVISO="Modo Jogo ativado, mas o GameMode nao esta instalado (sudo apt install gamemode)."
fi
notify "$AVISO"

# Guarda as configuracoes atuais para restaurar depois
EFEITOS_ANTES=$(gsettings get org.cinnamon desktop-effects 2>/dev/null)
NOTIF_ANTES=$(gsettings get org.cinnamon.desktop.notifications display-notifications 2>/dev/null)
CONKY_CMD=$(pgrep -ax conky | head -n1 | cut -d' ' -f2-)

restaurar() {
  [ -n "$EFEITOS_ANTES" ] && gsettings set org.cinnamon desktop-effects "$EFEITOS_ANTES" 2>/dev/null
  [ -n "$NOTIF_ANTES" ] && gsettings set org.cinnamon.desktop.notifications display-notifications "$NOTIF_ANTES" 2>/dev/null
  [ -n "$CONKY_CMD" ] && nohup $CONKY_CMD >/dev/null 2>&1 &
  notify "Modo Jogo desativado. Tudo voltou ao normal."
}
trap restaurar EXIT

# Reduz o que pesa: efeitos da area de trabalho, notificacoes e Conky
gsettings set org.cinnamon desktop-effects false 2>/dev/null
gsettings set org.cinnamon.desktop.notifications display-notifications false 2>/dev/null
[ -n "$CONKY_CMD" ] && pkill -x conky

# Abre a Steam
$STEAM_CMD >/dev/null 2>&1 &

# Espera a Steam abrir (ate 2 minutos) e depois fechar
for _ in $(seq 1 60); do
  pgrep -x steam >/dev/null && break
  sleep 2
done
while pgrep -x steam >/dev/null; do
  sleep 5
done
