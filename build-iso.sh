#!/usr/bin/env bash
# Gera uma ISO personalizada do Linux Mint com:
#  - Steam + GameMode + drivers Vulkan (64 e 32 bits) para DXVK/Proton
#  - Modo Jogo (atalho no menu)
#  - Tema escuro com acento roxo e swap comprimido (zram)
#
# Uso:    sudo ./build-iso.sh linuxmint-cinnamon-64bit.iso [saida.iso]
# Leve:   sudo LEVE=1 ./build-iso.sh linuxmint-cinnamon-64bit.iso
#         (remove LibreOffice, Thunderbird e outros apps pesados)
#
# Rode em Linux Mint ou Ubuntu (pode ser uma VM), com internet e ~15 GB livres.
# Os arquivos modo-jogo.sh e modo-jogo.desktop devem estar na mesma pasta.
# O script aceita automaticamente a licenca da Steam durante a instalacao.

set -euo pipefail

ISO_ORIGEM="${1:-}"
SAIDA="${2:-modojogo-mint.iso}"
AQUI="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/tmp/modojogo-build}"
LEVE="${LEVE:-0}"
R="$WORK/rootfs"
EXTRA="$WORK/extra"

# ---------- Verificacoes ----------
[ "$(id -u)" -eq 0 ] || { echo "Rode com sudo."; exit 1; }
[ -f "$ISO_ORIGEM" ] || { echo "Uso: sudo $0 linuxmint.iso [saida.iso]"; exit 1; }
for f in modo-jogo.sh modo-jogo.desktop; do
  [ -f "$AQUI/$f" ] || { echo "Falta o arquivo $f ao lado deste script."; exit 1; }
done

mkdir -p "$WORK"
LIVRE=$(df --output=avail -BG "$WORK" | tail -n1 | tr -dc '0-9')
[ "${LIVRE:-0}" -ge 15 ] || { echo "Precisa de ~15 GB livres em $WORK (tem ${LIVRE:-0} GB)."; exit 1; }

desmontar() {
  for m in run sys proc dev/pts dev; do
    mountpoint -q "$R/$m" && umount -lf "$R/$m" || true
  done
}
trap desmontar EXIT

# ---------- Ferramentas ----------
echo ">> Instalando ferramentas de build..."
apt-get update -qq
apt-get install -y -qq squashfs-tools xorriso >/dev/null

# ---------- Extrair o sistema da ISO ----------
echo ">> Extraindo o sistema da ISO (alguns minutos)..."
rm -rf "$R" "$EXTRA" "$WORK/filesystem.squashfs" "$WORK/md5sum.orig"
mkdir -p "$EXTRA"
xorriso -osirrox on -indev "$ISO_ORIGEM" \
  -extract /casper/filesystem.squashfs "$WORK/filesystem.squashfs" >/dev/null 2>&1 \
  || { echo "Nao achei /casper/filesystem.squashfs. Essa ISO e do Linux Mint/Ubuntu?"; exit 1; }
unsquashfs -f -d "$R" "$WORK/filesystem.squashfs" >/dev/null
rm -f "$WORK/filesystem.squashfs"

# ---------- Arquivos do Modo Jogo ----------
install -m 755 "$AQUI/modo-jogo.sh" "$R/usr/local/bin/modo-jogo"
install -m 644 "$AQUI/modo-jogo.desktop" "$R/usr/share/applications/modo-jogo.desktop"

# ---------- Preparar o chroot ----------
echo ">> Preparando o chroot..."
mount --bind /dev "$R/dev"
mount --bind /dev/pts "$R/dev/pts"
mount -t proc proc "$R/proc"
mount -t sysfs sys "$R/sys"
mount -t tmpfs tmpfs "$R/run"
RESOLV_LINK="$(readlink "$R/etc/resolv.conf" || true)"
rm -f "$R/etc/resolv.conf"
echo "nameserver 1.1.1.1" > "$R/etc/resolv.conf"

# ---------- Personalizar o sistema ----------
echo ">> Instalando Steam, GameMode e drivers Vulkan..."
chroot "$R" env LEVE="$LEVE" /bin/bash -s <<'CHROOT'
set -e
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

# Impede que servicos iniciem dentro do chroot
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# Bibliotecas de 32 bits (necessarias para a Steam e muitos jogos)
dpkg --add-architecture i386

# Licenca da Steam
echo "steam steam/question select I AGREE" | debconf-set-selections
echo "steam steam/license note" | debconf-set-selections

apt-get update
apt-get install -y gamemode steam-installer vulkan-tools zram-tools \
  mesa-vulkan-drivers libvulkan1 \
  mesa-vulkan-drivers:i386 libvulkan1:i386 libgl1-mesa-dri:i386

# Opcional: remover apps pesados
if [ "$LEVE" = "1" ]; then
  for p in 'libreoffice*' thunderbird hexchat transmission-gtk rhythmbox celluloid; do
    apt-get purge -y "$p" || true
  done
fi

# Tema escuro com acento roxo como padrao
cat > /usr/share/glib-2.0/schemas/zz_modojogo.gschema.override <<'EOF2'
[org.cinnamon.desktop.interface]
gtk-theme='Mint-Y-Dark-Purple'
icon-theme='Mint-Y-Purple'

[org.cinnamon.theme]
name='Mint-Y-Dark-Purple'

[org.cinnamon.desktop.wm.preferences]
theme='Mint-Y-Dark-Purple'
EOF2
glib-compile-schemas /usr/share/glib-2.0/schemas

# Limpeza
apt-get clean
rm -f /usr/sbin/policy-rc.d
rm -rf /var/lib/apt/lists/* /tmp/*
CHROOT

# Lista de pacotes (usada pelo instalador da ISO)
chroot "$R" dpkg-query -W --showformat='${Package} ${Version}\n' > "$EXTRA/filesystem.manifest"

# ---------- Fechar o chroot ----------
desmontar
rm -f "$R/etc/resolv.conf"
if [ -n "$RESOLV_LINK" ]; then ln -s "$RESOLV_LINK" "$R/etc/resolv.conf"; fi
du -sx --block-size=1 "$R" | cut -f1 > "$EXTRA/filesystem.size"

# ---------- Recompactar ----------
echo ">> Compactando o sistema (demora, pode levar de 20 a 60 minutos)..."
mksquashfs "$R" "$EXTRA/filesystem.squashfs" -comp xz -b 1M -noappend

# ---------- Atualizar o md5sum da ISO ----------
if xorriso -osirrox on -indev "$ISO_ORIGEM" -extract /md5sum.txt "$WORK/md5sum.orig" >/dev/null 2>&1; then
  grep -vE 'casper/filesystem\.(squashfs|size|manifest)$' "$WORK/md5sum.orig" > "$EXTRA/md5sum.txt" || true
  for f in filesystem.squashfs filesystem.size filesystem.manifest; do
    echo "$(md5sum "$EXTRA/$f" | cut -d' ' -f1)  ./casper/$f" >> "$EXTRA/md5sum.txt"
  done
fi

# ---------- Gerar a ISO ----------
echo ">> Gerando a ISO..."
rm -f "$SAIDA"
ARGS=( -overwrite on -indev "$ISO_ORIGEM" -outdev "$SAIDA" -boot_image any replay
  -map "$EXTRA/filesystem.squashfs" /casper/filesystem.squashfs
  -map "$EXTRA/filesystem.size" /casper/filesystem.size
  -map "$EXTRA/filesystem.manifest" /casper/filesystem.manifest )
if [ -f "$EXTRA/md5sum.txt" ]; then
  ARGS+=( -map "$EXTRA/md5sum.txt" /md5sum.txt )
fi
ARGS+=( -commit )
xorriso "${ARGS[@]}"

if [ -n "${SUDO_USER:-}" ]; then chown "$SUDO_USER" "$SAIDA" || true; fi
rm -rf "$WORK"

echo
echo "Pronto: $SAIDA"
echo "Teste primeiro em uma maquina virtual (VirtualBox ou QEMU) antes de gravar no pendrive."
