// BYPASS loopback test over a CH347T: shifts random data through the FPGA's
// 1-bit BYPASS register and compares TDO with TDI delayed by one bit.
//   bypass <factor> <bytes> [chunk=509] [depth=1] [lag]
// factor: 0=468.75k 1=937.5k 2=1.875M 3=3.75M 4=7.5M 5=15M 6=30M 7=60M
// lag: also print, per bit position in the byte, the mismatch rate of rx bit j
// against tx bit j-lag (lag 1 is the correct one).
#include "ch347.h"

int main(int argc, char **argv) {
	if (argc < 3) { fprintf(stderr, "usage: bypass <factor> <bytes> [chunk] [depth] [lag]\n"); return 1; }
	int factor = atoi(argv[1]);
	long total = atol(argv[2]);
	int chunk = argc > 3 ? atoi(argv[3]) : 509;
	int depth = argc > 4 ? atoi(argv[4]) : 1;
	int lagmode = argc > 5;
	open_cable(factor);
	tmsseq("1100");      // Select-DR, Select-IR, Capture-IR, Shift-IR
	uint8_t t[6] = {0,0,0,0,0,1}, d[6] = {1,1,1,1,1,1}, ir[6];
	bits(t, d, ir, 6);   // BYPASS = 111111, exit to Exit1-IR
	printf("IR capture: "); for (int i = 5; i >= 0; i--) printf("%d", ir[i]); printf("  (bit0..1 should be 01; bit4 INIT, bit5 DONE)\n");
	tmsseq("1100");      // Update-IR, Select-DR, Capture-DR, Shift-DR
	uint8_t *tx = malloc(total), *rx = malloc(total);
	srand(12345);
	for (long i = 0; i < total; i++) tx[i] = rand() & 0xff;
	memset(rx, 0, total);
	double t0 = now();
	int r = jtag_stream(tx, rx, total, chunk, depth);
	double dt = now() - t0;
	long err = 0, first_err = -1;
	for (long j = 1; j < total * 8; j++) {
		int rb = (rx[j>>3] >> (j&7)) & 1; long k = j - 1;
		if (rb != ((tx[k>>3] >> (k&7)) & 1)) { if (first_err < 0) first_err = j - 1; err++; }
	}
	if (lagmode) {
		for (int lag = -4; lag <= 12; lag++) {
			printf("lag %3d:", lag);
			for (int pos = 0; pos < 8; pos++) {
				long m = 0, c = 0;
				for (long j = 64 + pos; j < total * 8 - 64; j += 8) {
					int rb = (rx[j>>3] >> (j&7)) & 1; long k = j - lag;
					m += rb != ((tx[k>>3] >> (k&7)) & 1); c++;
				}
				printf(" %5.3f", (double)m / c);
			}
			printf("\n");
		}
	}
	close_cable();
	printf("factor %d (%.3f MHz) chunk %d depth %d: %ld bits compared, %ld mismatches, first at bit %ld; %.2f s, %.2f Mbit/s%s\n",
		factor, ch347_hz[factor] / 1e6, chunk, depth, total * 8 - 1, err, first_err, dt, total * 8 / dt / 1e6, r ? " [STREAM ERROR]" : "");
	return (err || r) ? 3 : 0;
}
