#!/bin/sh
# card.sh [<design>...]: each design (all by default) synthesised by yosys,
# placed and routed by openXUS (the `nextpnr` submodule: Project-Inkwell/
# nextpnr's `ultrascale` branch) on a chipdb made
# from openXUS-db (the `db` submodule), assembled by tools/fasm2bit.py,
# loaded into the AS02MC04's volatile configuration memory over JTAG on the
# rig, and checked by reading its registers back:
#
#   blinky    the counter counts at CFGMCLK's rate (45 to 55 MHz)
#   serv      SERV's LED register toggles, and its registers t1 and a0 read
#             0x00100000 and 0x40000000, as Vivado's own SERV's do
#   picorv32  PicoRV32 runs its program from block RAM: the count of the
#             primes below 2048 (309) in its result register, its LED toggling
#   refclk    the PCIe slot's 100 MHz reference clock, through IBUFDS_GTE4 and
#             a BUFG_GT where the PCIe endpoint takes it, counts at 95-105 MHz
#             (the slot drives it only for a moment after the host boots: load,
#             reboot the host, then read)
#   pcie      pci_eerie (the `pci_eerie` submodule), a soft PCIe endpoint on
#             lane 0's GTY: its state read back (it does not enumerate yet)
#
# Says PASS or FAIL for each and exits non-zero if any failed. Only the
# volatile configuration memory is written: never the flash.
#
#   RIG      the rig's ssh address (required); `cfg` (tools/ch347) built in
#            ~/opt/src there
#   WORK     where builds go (default ~/.cache/openxus-flow)
#   NEXTPNR  the nextpnr checkout (default the `nextpnr` submodule)
#   DB       the database (default the `db` submodule's xcku3p)
#   IMAGE    the image yosys and nextpnr build and run in (default
#            localhost/openxus-flow, built from the Containerfile)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
RIG=${RIG:?set RIG to the rig ssh address}
WORK=${WORK:-$HOME/.cache/openxus-flow}
NEXTPNR=${NEXTPNR:-$REPO/nextpnr}
DB=${DB:-$REPO/db/xcku3p}
IMAGE=${IMAGE:-localhost/openxus-flow}
TOOLS=$REPO/tools
PART=xcku3p-ffvb676-2-e
SERV_COMMIT=f200eb2
PICORV32_COMMIT=ef203c2
# The seed SERV is placed with: see the README (Timing).
SERV_SEED=2
mkdir -p "$WORK"
run() { podman run --rm --userns=keep-id -v "$NEXTPNR":/src -v "$WORK":/work -w /work "$IMAGE" sh -c "$1"; }

# The image, and nextpnr built in it into the work directory (ninja: only
# what changed). The xilinx uarch builds no chipdb of its own here.
[ "$IMAGE" != localhost/openxus-flow ] || podman build -q -t "$IMAGE" "$REPO" > /dev/null || exit 1
run 'mkdir -p nextpnr-build && cd nextpnr-build && { [ -f build.ninja ] || cmake -G Ninja /src -DARCH=himbaechel -DHIMBAECHEL_UARCH=xilinx \
        -DHIMBAECHEL_XILINX_DEVICES= -DHIMBAECHEL_PRJXRAY_DB=none -DCMAKE_BUILD_TYPE=Release -DBUILD_PYTHON=OFF -DBUILD_GUI=OFF > cmake.log; } \
     && ninja nextpnr-himbaechel bbasm > ninja.log' || { echo "nextpnr did not build: $WORK/nextpnr-build"; exit 1; }
# The node list is kept compressed; the generator reads it whole.
if [ ! -f "$DB/xcku3p/nodes.txt" ] || [ "$DB/xcku3p/nodes.txt.zst" -nt "$DB/xcku3p/nodes.txt" ]; then
    zstd -q -d -f "$DB/xcku3p/nodes.txt.zst" -o "$DB/xcku3p/nodes.txt" || exit 1
fi
# The chipdb, made again when the database or the generator changed.
newest=$(find "$DB" "$NEXTPNR/himbaechel/uarch/xilinx/gen" -newer "$WORK/ku3p.bin" -type f 2>/dev/null | head -1)
if [ ! -f "$WORK/ku3p.bin" ] || [ -n "$newest" ]; then
    echo "chipdb from $DB"
    PYTHONPATH=$NEXTPNR/himbaechel python3 "$NEXTPNR/himbaechel/uarch/xilinx/gen/xilinx_gen.py" --xray "$DB" --metadata "$DB" \
        --device xcku3p --bba "$WORK/ku3p.bba" > "$WORK/ku3p-gen.log" 2>&1 || { echo "the generator failed: $WORK/ku3p-gen.log"; exit 1; }
    rm -f "$WORK/ku3p.bin"
    run 'nextpnr-build/bba/bbasm --l ku3p.bba ku3p.bin' || exit 1
fi

# One design: synthesised, placed and routed, assembled, its registers'
# places in a readback written, loaded. $1 the design, $2 yosys's sources,
# $3 what synthesis may not use (the design's memories as registers by
# default), $4 nextpnr's seed (none by default: nextpnr's own first state).
build() {
    leave_out=${3:--nobram -nolutram -nosrl -nodsp -nocarry -nowidelut}
    d=$WORK/$1
    mkdir -p "$d"
    cp "$HERE/designs/$1"/* "$d/"
    run "cd $1 && yosys -q -l synth.log -p 'read_verilog -sv $2; synth_xilinx -family xcup -top top -flatten $leave_out; write_json design.json' > /dev/null 2>&1 \
        && ../nextpnr-build/nextpnr-himbaechel --chipdb ../ku3p.bin --device $PART -o xdc=design.xdc --json design.json \
           -o fasm=design.fasm --router router2 ${4:+--seed $4} --write routed.json > pnr.log 2>&1" || { echo "$1: synthesis or place and route failed ($d)"; return 1; }
    python3 "$TOOLS/fasm2bit.py" "$DB" xcku3p $PART 0x04A63093 "$d/design.fasm" "$d/design.bit" 2> "$d/fasm2bit.log" || { echo "$1: assembly failed"; return 1; }
    python3 "$TOOLS/locations.py" "$DB" xcku3p "$d/routed.json" > "$d/design.ll" || return 1
    scp -q "$d/design.bit" "$RIG:/tmp/card-$1.bit" && ssh "$RIG" "cd ~/opt/src && timeout 120 ./cfg 4 load /tmp/card-$1.bit" > "$d/load.log" 2>&1 \
        || { echo "$1: the load failed ($d/load.log)"; return 1; }
}

blinky() {
    build blinky blinky.v || return 1
    d=$WORK/blinky
    scp -q "$d/design.ll" "$RIG:/tmp/card-blinky.ll" && ssh "$RIG" "cd ~/opt/src && timeout 60 ./cfg 4 count /tmp/card-blinky.ll 2 500" > "$d/count.log" 2>&1
    mhz=$(grep -o -- '-> [0-9.]* MHz' "$d/count.log" | head -1 | cut -d' ' -f2)
    echo "blinky: counts at ${mhz:-?} MHz"
    awk -v m="${mhz:-0}" 'BEGIN { exit !(m >= 45 && m <= 55) }'
}

serv() {
    [ -d "$WORK/serv-source" ] || git clone -q https://github.com/olofk/serv.git "$WORK/serv-source" || return 1
    git -C "$WORK/serv-source" checkout -q $SERV_COMMIT || return 1
    rm -rf "$WORK/serv/serv" && mkdir -p "$WORK/serv" && cp -r "$WORK/serv-source" "$WORK/serv/serv"
    # yosys elaborates servant's default program as well as the one given.
    cp "$WORK/serv-source/sw/zephyr_hello.hex" "$WORK/serv/"
    s=serv/servant
    build serv "serv_card.v $s/servant.v $s/servant_gpio.v $s/servant_mux.v $s/servant_ram.v $s/servant_timer.v serv/servile/*.v serv/rtl/*.v" "" "$SERV_SEED" || return 1
    d=$WORK/serv
    # SERV's register file is registers: register r's bit 2k+j is memory[r*16+k][j].
    { head -2 "$d/design.ll"
      for r in 6 10; do for k in $(seq 0 15); do for j in 0 1; do
          grep "Net=soc.rf_ram.memory\[$((r*16+k))\]\[$j\]$" "$d/design.ll"; done; done; done
      grep "Net=soc.q$" "$d/design.ll"; } > "$d/watched.ll"
    scp -q "$d/watched.ll" "$RIG:/tmp/card-serv.ll" && ssh "$RIG" "cd ~/opt/src && timeout 60 ./cfg 4 bits /tmp/card-serv.ll 16 500" > "$d/bits.log" 2>&1
    python3 - "$d/bits.log" <<'EOF'
import sys
reads = [line.split()[4] for line in open(sys.argv[1]) if line.startswith("read") and len(line.split()) > 4]
reads = [bits for bits in reads if len(bits) == 65]
value = lambda bits: int(bits[::-1], 2)
t1 = {value(bits[0:32]) for bits in reads}
a0 = {value(bits[32:64]) for bits in reads}
led = {bits[64] for bits in reads}
print("serv: %d reads, t1 %s, a0 %s, LED %s" % (len(reads), sorted("%08x" % v for v in t1), sorted("%08x" % v for v in a0), sorted(led)))
sys.exit(0 if reads and t1 == {0x00100000} and a0 == {0x40000000} and led == {"0", "1"} else 1)
EOF
}

picorv32() {
    [ -d "$WORK/picorv32-source" ] || git clone -q https://github.com/YosysHQ/picorv32.git "$WORK/picorv32-source" || return 1
    git -C "$WORK/picorv32-source" checkout -q $PICORV32_COMMIT || return 1
    d=$WORK/picorv32
    rm -rf "$d" && mkdir -p "$d" && cp "$HERE/designs/picorv32"/* "$d/" && cp "$WORK/picorv32-source/picorv32.v" "$d/"
    # The program, compiled for rv32i, as the memory's 2048 words.
    podman build -q -t localhost/openxus-firmware "$HERE/designs/picorv32" > /dev/null || return 1
    podman run --rm --userns=keep-id -v "$d":/w -w /w localhost/openxus-firmware sh -c \
        'riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -Os -ffreestanding -nostdlib -T link.ld -o firmware.elf start.S firmware.c 2> /dev/null \
         && riscv64-unknown-elf-objcopy -O binary firmware.elf firmware.bin \
         && { od -An -v -tx4 -w4 firmware.bin | tr -d " "; n=$(( $(stat -c %s firmware.bin) / 4 )); while [ $n -lt 2048 ]; do echo 00000000; n=$((n+1)); done; } > firmware.hex' \
        || { echo "picorv32: the program did not compile"; return 1; }
    build picorv32 "top.v picorv32.v" "-nolutram -nosrl -nodsp -nocarry -nowidelut" || return 1
    { head -2 "$d/design.ll"
      for k in $(seq 0 31); do grep "Net=result\[$k\]$" "$d/design.ll"; done
      grep "Net=led_register$" "$d/design.ll"; } > "$d/watched.ll"
    scp -q "$d/watched.ll" "$RIG:/tmp/card-picorv32.ll" && ssh "$RIG" "cd ~/opt/src && timeout 60 ./cfg 4 bits /tmp/card-picorv32.ll 12 400" > "$d/bits.log" 2>&1
    python3 - "$d/bits.log" <<'EOF2'
import sys
reads = [line.split()[4] for line in open(sys.argv[1]) if line.startswith("read") and len(line.split()) > 4]
reads = [bits for bits in reads if len(bits) == 33]
result = {int(bits[0:32][::-1], 2) for bits in reads}
led = {bits[32] for bits in reads}
print("picorv32: %d reads, result %s, LED %s" % (len(reads), sorted(result), sorted(led)))
sys.exit(0 if reads and result == {309} and led == {"0", "1"} else 1)
EOF2
}

refclk() {
    build refclk "gt_blackbox.v top.v" || return 1
    d=$WORK/refclk
    # Each counter as the rig's `count` reads one: its bits named count[k].
    for counter in count ctrl txc; do
        { head -2 "$d/design.ll"; grep -E "Net=$counter\[[0-9]+\]$" "$d/design.ll" | sed "s/Net=$counter\[/Net=count[/"; } > "$d/$counter.ll"
        scp -q "$d/$counter.ll" "$RIG:/tmp/card-refclk-$counter.ll"
    done
    { head -2 "$d/design.ll"; grep -E "Net=lock_q$" "$d/design.ll"; } > "$d/lock.ll"
    scp -q "$d/lock.ll" "$RIG:/tmp/card-refclk-lock.ll"
    ssh "$RIG" "cd ~/opt/src && for c in count ctrl txc; do echo \"== \$c\"; timeout 60 ./cfg 4 count /tmp/card-refclk-\$c.ll 2 500; done; echo '== lock'; timeout 60 ./cfg 4 bits /tmp/card-refclk-lock.ll 2 300" > "$d/count.log" 2>&1
    rate() { awk -v c="== $1" '$0 == c { on = 1; next } /^==/ { on = 0 } on' "$d/count.log" | grep -o -- '-> [0-9.]* MHz' | head -1 | cut -d' ' -f2; }
    mhz=$(rate count)
    echo "refclk: the reference clock counts at ${mhz:-?} MHz, TXOUTCLK at $(rate txc) MHz, CFGMCLK at $(rate ctrl) MHz; CPLLLOCK $(awk '/^== lock/ { on = 1; next } on && /^read/ { print $4 }' "$d/count.log" | tr '\n' ' ')"
    awk -v m="${mhz:-0}" 'BEGIN { exit !(m >= 95 && m <= 105) }'
}

pcie() {
    d=$WORK/pcie
    rm -rf "$d" && mkdir -p "$d" && cp "$HERE/designs/pcie"/* "$d/" && cp "$REPO/pci_eerie/rtl"/* "$d/"
    srcs="gt_blackbox.v top.v $(tr '\n' ' ' < "$REPO/pci_eerie/rtl/files.f")"
    build pcie "$srcs" "-nolutram -nosrl -nodsp -nocarry -nowidelut" || return 1
    { head -2 "$d/design.ll"
      for k in $(seq 0 31); do grep "Net=pcie_diag\[$k\]$" "$d/design.ll"; done; } > "$d/watched.ll"
    scp -q "$d/watched.ll" "$RIG:/tmp/card-pcie.ll" && ssh "$RIG" "cd ~/opt/src && timeout 60 ./cfg 4 bits /tmp/card-pcie.ll 4 400" > "$d/bits.log" 2>&1
    cat "$d/bits.log"
}

failed=0
for design in ${*:-blinky serv picorv32}; do
    if $design; then echo "PASS $design"; else echo "FAIL $design"; failed=1; fi
done
exit $failed
