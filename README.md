# openXUS-flow

This repository holds the flow we currently use for development of the openXUS+ nextpnr
backend for the AMD Kintex UltraScale+ XCKU3P. The specific board we use is an
"Alibaba Cloud"-branded Alpha Data AS02MC04 network interface card, which are very cheap
when imported used from China.

This flow includes synthesis with yosys, pnr using our openXUS+
(the `ultrascale` branch of [our nextpnr](https://github.com/Project-Inkwell/nextpnr/tree/ultrascale),
and bitstream generation using a proof-of-concept bitstream creator (`tools/fasm2bit.py`).
We also have a little script (`card/card.sh`) that we use to run the bitstream on a
network-connected test rig (an old mainboard) that holds our card.

To run the full flow:

    git clone --recurse-submodules https://github.com/Project-Inkwell/openXUS-flow.git
    RIG=<user>@<rig> openXUS-flow/card/card.sh

## Testing/Verification

Currently we mainly use `card/card.sh [blinky] [serv] [picorv32]` for checking our DB/nextpnr
changes. This script builds nextpnr and the chipdb, synthesises, places, routes and generates
a bitstream. Then loads it into the FPGA's configuration memory and reads its registers back
to check if the designs behave as expected. For blinky this is just a counter that we can check
to see if it has reached the expected number at a given clock rate. For the riscv cores, we
have little assembly programs that write to registers that we then check to see if they
contain the expected value after the cores have run.

The designs and ASM can be found in the `card/designs/` directory.

The hardware testing setup we currently use is just a motherboard from an old PC,
with the FPGA card powered by the PCIe slot. For programming, the card's JTAG connector
connected to a CH347-based JTAG-to-USB adapter, which is itself plugged into one of the
USB ports of the motherboard. For details, see `tools/ch347/README.md`, and Cupiad's
great collection of resources for the card/programmer used in this project:
https://github.com/Cupiad/Alibaba-AS02MC04

## This branch: `pcie`

Work toward a PCIe endpoint, not yet working: `nextpnr` is our nextpnr's
`ultrascale-pcie` branch (the transceivers, the PCIe block, and the ties
the tool holds a hard block's unconnected inputs at), and `card.sh` has two
more checks:

- **refclk**: the slot's 100 MHz reference clock reaches the fabric through
  the transceiver quad's IBUFDS_GTE4 and a BUFG_GT, and a channel's CPLL
  locks to it. The host's BIOS drives the clock only for about 54 ms after
  it boots, so the check is: load, reboot the host, read.
- **pcie**: pci_eerie (`pci_eerie/`, a soft PCIe endpoint written for
  7-series transceivers) on lane 0's GTYE4_CHANNEL: its state read back. It
  does not enumerate yet; its transceiver wrapper lacks the reset sequence
  and clocking a GTY in PCIe mode needs.

## License

The code in this repository is licensed under the ISC license. See [LICENSE](LICENSE).
The submodules (`db`, `nextpnr`, `pci_eerie`) and the third-party designs `card/card.sh` fetches (SERV,
PicoRV32) are under their own licenses.

## Disclaimer

This project is not affiliated with, endorsed by, or sponsored by AMD/Xilinx, Alpha Data or
Alibaba Cloud. AMD, Xilinx, Kintex, UltraScale+ and Vivado are trademarks of Advanced Micro
Devices, Inc.; other names are trademarks of their respective owners. They are used here only
to describe the hardware this flow targets.
