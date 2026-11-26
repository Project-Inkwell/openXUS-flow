// Xilinx UltraScale+ (xcku3p) over JTAG on a CH347T (1a86:55dd).
// Volatile configuration memory only: nothing here touches the flash.
//   cfg <factor> regs                      read configuration registers
//   cfg <factor> load <file.bit>           JPROGRAM, CFG_IN, JSTART (SRAM only), each
//                                          bit checked by its TDO echo; retried up to
//                                          CFG_TRIES (3) times
//   cfg <factor> frames <far> <n>          readback capture of n frames from far
//   cfg <factor> bits <file.ll> [reads] [gap_ms]
//                                          each bit's register value, every read
//   cfg <factor> capdiff <far> <n> [gap_ms] two of those, printing the words that differ
//   cfg <factor> sample <bits> [reads] [gap_ms]
//                                          boundary-scan SAMPLE snapshots, changed bits
//   cfg <factor> count <file.ll> [reads] [gap_ms]
//                                          readback capture of the bits the
//                                          logic location file names; decodes the
//                                          blinky's 26-bit counter
// factor: 0=468.75k 1=937.5k 2=1.875M 3=3.75M 4=7.5M 5=15M 6=30M 7=60M
#include "ch347.h"
#include <unistd.h>

// bytes per 0xd4 command (509: one 512-byte USB packet) and commands in flight;
// overridable with CFG_CHUNK and CFG_DEPTH
static int CHUNK = 509, DEPTH = 4, g_factor;
#define FRAME_WORDS 93

// from Run-Test/Idle: shift n 32-bit words MSB first into DR, end in Run-Test/Idle
static void shift_words(const uint32_t *w, int n, uint32_t *out) {
	uint8_t *t = calloc(n * 32, 1), *d = malloc(n * 32), *q = malloc(n * 32);
	tmsseq("100");
	for (int i = 0; i < n*32; i++) { d[i] = (w[i/32] >> (31 - i%32)) & 1; t[i] = i == n*32-1; }
	bits(t, d, q, n*32);
	tmsseq("10");
	if (out) for (int k = 0; k < n; k++) { uint32_t v = 0; for (int i = 0; i < 32; i++) v = v << 1 | q[k*32+i]; out[k] = v; }
	free(t); free(d); free(q);
}
// RTI clocks without per-bit encoding: zero bytes with TMS low stay in Run-Test/Idle
static void idle_clocks(long n) {
	long bytes = n / 8;
	if (bytes) jtag_stream(NULL, NULL, bytes, CHUNK, DEPTH);
	if (n % 8) rti_clocks(n % 8);
}
#define T1W(reg) ((1u<<29)|(2u<<27)|((uint32_t)(reg)<<13)|1)
#define T1R(reg, n) ((1u<<29)|(1u<<27)|((uint32_t)(reg)<<13)|(n))
#define NOOP 0x20000000
#define SYNC 0xAA995566
enum { R_CRC = 0, R_FAR = 1, R_FDRO = 3, R_CMD = 4, R_STAT = 7 };
enum { C_RCFG = 4, C_DESYNC = 13 };

static uint32_t read_reg(int reg) {
	uint32_t p[5] = {SYNC, NOOP, T1R(reg, 1), NOOP, NOOP};
	uint32_t z = 0, v;
	tmsseq("11111"); tmsseq("0");
	shift_ir(0x05);
	shift_words(p, 5, NULL);
	shift_ir(0x04);
	shift_words(&z, 1, &v);
	tmsseq("11111"); tmsseq("0");
	return v;
}

static uint8_t rev8(uint8_t b) { b = (b & 0xF0) >> 4 | (b & 0x0F) << 4; b = (b & 0xCC) >> 2 | (b & 0x33) << 2; return (b & 0xAA) >> 1 | (b & 0x55) << 1; }
// One attempt: JPROGRAM, CFG_IN, the data, JSTART. TDO during CFG_IN is TDI
// delayed by the 32-bit CFG_IN register, so the echo checks every bit the
// FPGA shifted in: a lost bit, an extra clock or a TAP that left Shift-DR
// all break it. Returns 0 when DONE rose and the echo was exact.
static int load_once(const uint8_t *d, long n, uint8_t *rx, long echo_end) {
	double t0 = now();
	tmsseq("11111"); tmsseq("0");
	shift_ir(0x0B);                         // JPROGRAM
	usleep(20000);
	int cap, tries = 0;
	do { cap = shift_ir(0x3f); usleep(1000); } while (!(cap & 0x10) && ++tries < 2000);
	if (!(cap & 0x10)) { fprintf(stderr, "INIT never rose (IR capture 0x%02x)\n", cap); return 1; }
	idle_clocks(10000);
	shift_ir(0x05);                         // CFG_IN
	tmsseq("100");                          // Select-DR, Capture-DR, Shift-DR
	double t1 = now();
	if (jtag_stream(d, rx, n - 1, CHUNK, DEPTH)) { fprintf(stderr, "stream failed\n"); return 2; }
	double t2 = now();
	uint8_t t[8] = {0,0,0,0,0,0,0,1}, x[8];
	for (int i = 0; i < 8; i++) x[i] = (d[n-1] >> i) & 1;   // LSB first (already reversed), TMS on the last bit
	bits(t, x, NULL, 8);
	tmsseq("10");                           // Update-DR, Run-Test/Idle
	shift_ir(0x0C);                         // JSTART
	idle_clocks(20000);
	tmsseq("11111"); tmsseq("0");
	cap = shift_ir(0x3f);
	double t3 = now();
	// the echo holds up to the DESYNC command; after it the CFG_IN path no longer
	// echoes (4 bits differ, always the same), and only NOOPs follow
	long bad = 0, first = -1, nbits = echo_end * 8;
	for (long j = 32; j < nbits; j++) {
		long k = j - 32;
		if (((rx[j>>3] >> (j&7)) & 1) != ((d[k>>3] >> (k&7)) & 1)) { if (first < 0) first = k; bad++; }
	}
	printf("  JPROGRAM->INIT %d polls; shifted %ld bits in %.2f s (%.2f Mbit/s); TDO echo: %ld mismatches%s",
		tries, n * 8, t2 - t1, n * 8 / (t2 - t1) / 1e6, bad, bad ? "" : "\n");
	if (bad) printf(", first at data bit %ld (%.1f%%)\n", first, 100.0 * first / nbits);
	printf("  JSTART: IR capture 0x%02x INIT=%d DONE=%d; attempt %.2f s\n", cap, (cap >> 4) & 1, (cap >> 5) & 1, t3 - t0);
	return (bad || !(cap & 0x20)) ? 3 : 0;
}
static int load(const char *path) {
	double t0 = now();
	FILE *f = fopen(path, "rb"); if (!f) { perror(path); return 1; }
	fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
	uint8_t *b = malloc(sz); if (fread(b, 1, sz, f) != (size_t)sz) { fprintf(stderr, "short read\n"); return 1; } fclose(f);
	// .bit header: <len16><data> <len16=1> then 'a'..'d' each <key><len16><str>, then 'e'<len32><data>
	long p = 2 + (b[0] << 8 | b[1]); p += 2;
	while (p < sz && b[p] != 'e') { p++; p += 2 + (b[p] << 8 | b[p+1]); }
	if (p >= sz) { fprintf(stderr, "no e field\n"); return 1; }
	long n = (long)b[p+1] << 24 | b[p+2] << 16 | b[p+3] << 8 | b[p+4]; p += 5;
	if (p + n != sz) { fprintf(stderr, "bad length %ld + %ld != %ld\n", p, n, sz); return 1; }
	uint8_t *d = b + p, *rx = malloc(n);
	long echo_end = n - 1;   // byte where the TDO echo check stops: the DESYNC packet, if any
	static const uint8_t desync[8] = {0x30, 0x00, 0x80, 0x01, 0x00, 0x00, 0x00, 0x0d};
	for (long i = 0; i + 8 <= n; i += 4) if (!memcmp(d + i, desync, 8)) echo_end = i;
	for (long i = 0; i < n; i++) d[i] = rev8(d[i]);   // configuration data goes MSB first
	int attempts = getenv("CFG_TRIES") ? atoi(getenv("CFG_TRIES")) : 3, r = 1;
	printf("bitstream: %ld bytes of configuration data; %.3f MHz, chunk %d, depth %d, up to %d attempts\n",
		n, ch347_hz[g_factor] / 1e6, CHUNK, DEPTH, attempts);
	for (int a = 1; a <= attempts; a++) {
		printf("attempt %d:\n", a);
		if (!(r = load_once(d, n, rx, echo_end))) break;
	}
	printf("%s in %.2f s\n", r ? "LOAD FAILED" : "loaded", now() - t0);
	free(rx); free(b);
	return r;
}

// Readback capture, UltraScale style (XAPP1230 Table 5): there is no GCAPTURE;
// with CTL1.CAPTURE (bit 23) set, a frame readback returns the registers' live
// state, inverted for CLB registers. Then CAPTURE is cleared again. Reads only:
// no SHUTDOWN, no JPROGRAM, no GRESTORE, no write to frame data. XAPP1230 asks
// for the user clock to be stopped so the snapshot is consistent; this design's
// clock cannot be stopped, so bits that toggle during the read may be skewed.
// Returns the time the read was issued; out gets nwords raw FDRO words.
enum { R_MASK = 6, R_CTL1 = 0x18 };
static double capture_and_read(uint32_t far, uint32_t *out, int nwords) {
	uint32_t cmd[] = {
		0xFFFFFFFF, SYNC, NOOP,
		T1W(R_CMD), 0,                      // NULL
		T1W(R_MASK), 0x00800000,            // CAPTURE bit writable
		T1W(R_CTL1), 0x00800000,            // CAPTURE on
		NOOP, NOOP, NOOP, NOOP, NOOP, NOOP, NOOP, NOOP,
		T1W(R_FAR), far,
		T1W(R_CMD), C_RCFG,
		T1R(R_FDRO, 0), (2u<<29)|(1u<<27)|(uint32_t)nwords,
		NOOP,
	};
	tmsseq("11111"); tmsseq("0");
	shift_ir(0x05);                         // CFG_IN
	double t = now();
	shift_words(cmd, sizeof cmd / 4, NULL);
	shift_ir(0x04);                         // CFG_OUT
	tmsseq("100");                          // Shift-DR
	long nb = (long)nwords * 4;
	uint8_t *rx = malloc(nb);
	jtag_stream(NULL, rx, nb, CHUNK, DEPTH);
	tmsseq("110");                          // Exit1-DR, Update-DR, Run-Test/Idle
	for (int k = 0; k < nwords; k++) {      // first bit out is the word's MSB
		uint32_t v = 0;
		for (int i = 0; i < 32; i++) { long j = (long)k * 32 + i; v = v << 1 | ((rx[j>>3] >> (j&7)) & 1); }
		out[k] = v;
	}
	free(rx);
	uint32_t end[] = { 0xFFFFFFFF, SYNC, NOOP,
		T1W(R_MASK), 0x00800000, T1W(R_CTL1), 0,   // CAPTURE off
		T1W(R_MASK), 0,
		T1W(R_CMD), C_DESYNC, NOOP, NOOP, NOOP, NOOP };
	tmsseq("11111"); tmsseq("0");
	shift_ir(0x05);
	shift_words(end, sizeof end / 4, NULL);
	tmsseq("11111"); tmsseq("0");
	return t;
}

struct llbit { uint32_t far; int off; unsigned long place; char net[96]; };
static int read_ll(const char *path, struct llbit *v, int max) {
	FILE *f = fopen(path, "r"); if (!f) { perror(path); exit(1); }
	char line[512]; int n = 0;
	while (fgets(line, sizeof line, f) && n < max) {
		unsigned long boff; unsigned far; int off;
		if (sscanf(line, "Bit %lu %x %d", &boff, &far, &off) != 3) continue;
		char *net = strstr(line, "Net=");
		if (!net) continue;
		v[n].far = far; v[n].off = off; v[n].place = boff;
		sscanf(net + 4, "%95s", v[n].net);
		n++;
	}
	fclose(f);
	return n;
}
// counter bit of a net: count_reg_n_0_[k] (Vivado's name) or count[k]
// (nextpnr's) is count[k]; led_OBUF[k] is count[22+k]
static int count_bit(const char *net) {
	int k;
	if (sscanf(net, "count_reg_n_0_[%d]", &k) == 1) return k;
	if (sscanf(net, "count[%d]", &k) == 1) return k;
	if (sscanf(net, "led_OBUF[%d]", &k) == 1) return 22 + k;
	return -1;
}

int main(int argc, char **argv) {
	if (argc < 3) { fprintf(stderr, "usage: cfg <factor> regs | load <file.bit> | frames <far> <n> | count <file.ll> [reads] [gap_ms] | bits <file.ll> [reads] [gap_ms]\n"); return 1; }
	if (getenv("CFG_CHUNK")) CHUNK = atoi(getenv("CFG_CHUNK"));
	if (getenv("CFG_DEPTH")) DEPTH = atoi(getenv("CFG_DEPTH"));
	g_factor = atoi(argv[1]);
	open_cable(g_factor);
	int rc = 0;
	if (!strcmp(argv[2], "regs")) {
		static const struct { int r; const char *n; } regs[] = {
			{0x01,"FAR"},{0x05,"CTL0"},{0x06,"MASK"},{0x07,"STAT"},{0x09,"COR0"},{0x0C,"IDCODE"},
			{0x0E,"COR1"},{0x10,"WBSTAR"},{0x11,"TIMER"},{0x16,"BOOTSTS"},{0x18,"CTL1"},{0x1F,"BSPI"}};
		for (unsigned i = 0; i < sizeof regs / sizeof regs[0]; i++)
			printf("%-8s (0x%02x) = 0x%08x\n", regs[i].n, regs[i].r, read_reg(regs[i].r));
		int cap = shift_ir(0x3f);
		printf("IR capture 0x%02x: INIT=%d DONE=%d\n", cap, (cap >> 4) & 1, (cap >> 5) & 1);
	} else if (!strcmp(argv[2], "load") && argc > 3) {
		rc = load(argv[3]);
		printf("STAT = 0x%08x  FAR = 0x%08x  COR0 = 0x%08x\n", read_reg(R_STAT), read_reg(R_FAR), read_reg(0x09));
	} else if (!strcmp(argv[2], "frames") && argc > 4) {
		uint32_t far = strtoul(argv[3], NULL, 0); int nf = atoi(argv[4]);
		int nw = (nf + 2) * FRAME_WORDS;
		uint32_t *w = malloc(nw * 4);
		capture_and_read(far, w, nw);
		for (int k = 0; k < nw; k++) if (w[k]) printf("word %4d (frame %d + %2d): %08x\n", k, k / FRAME_WORDS, k % FRAME_WORDS, w[k]);
		printf("STAT = 0x%08x\n", read_reg(R_STAT));
	} else if (!strcmp(argv[2], "count") && argc > 3) {
		static struct llbit ll[4096];
		int n = read_ll(argv[3], ll, 4096);
		int reads = argc > 4 ? atoi(argv[4]) : 2, gap = argc > 5 ? atoi(argv[5]) : 1000;
		// The frames the bits are in, read in one capture from the first: each
		// bit by its place in a readback of the image (the .ll's first number,
		// frame place times FRAME_WORDS * 32 plus the bit, pad frames counted).
		unsigned long first = ll[0].place / (FRAME_WORDS * 32), last = first;
		uint32_t far = ll[0].far;
		for (int i = 0; i < n; i++) {
			unsigned long frame = ll[i].place / (FRAME_WORDS * 32);
			if (frame < first) { first = frame; far = ll[i].far; }
			if (frame > last) last = frame;
		}
		int frames = (int)(last - first + 1);
		// The readback pipeline: a frame buffer (93 words) plus 25 words for this command
		// stream, measured by reading 0x00085a0c with CAPTURE off, whose static words 45/46
		// came out at 163/164 (and the next frame's at 256/257 with CAPTURE on).
		const int start = 118;
		int nw = start + frames * FRAME_WORDS;
		uint32_t *w = malloc(nw * 4);
		double t_prev = 0; uint32_t c_prev = 0;
		for (int r = 0; r < reads; r++) {
			if (r) usleep(gap * 1000);
			double t = capture_and_read(far, w, nw);
			uint32_t raw = 0;
			for (int i = 0; i < n; i++) {
				int cb = count_bit(ll[i].net); if (cb < 0) continue;
				unsigned long at = ll[i].place - first * FRAME_WORDS * 32;
				int bit = (w[start + at / 32] >> (at % 32)) & 1;
				raw |= (uint32_t)bit << cb;
			}
			uint32_t inv = ~raw & 0x3ffffff;
			printf("read %d: t=%.3f s  raw=0x%07x  count=~raw=0x%07x (%8u)  leds=count[25:22]=%x",
				r, t, raw, inv, inv, inv >> 22);
			if (r) {
				double dt = t - t_prev;
				uint32_t d = (inv - c_prev) & 0x3ffffff;
				printf("  delta=%u in %.3f s -> %.2f MHz (raw-polarity reading would give %.2f MHz)", d, dt, d / dt / 1e6, ((c_prev - inv) & 0x3ffffff) / dt / 1e6);
			}
			printf("\n");
			t_prev = t; c_prev = inv;
		}
		printf("STAT = 0x%08x\n", read_reg(R_STAT));
	} else if (!strcmp(argv[2], "bits") && argc > 3) {
		// Each bit of a .ll, its register's value as the capture reads it --
		// inverted, as a CLB register reads back -- each read a line: the
		// bits in the .ll's order, first on the left, and as hex, the first
		// bit the least significant.
		static struct llbit ll[4096];
		int n = read_ll(argv[3], ll, 4096);
		int reads = argc > 4 ? atoi(argv[4]) : 2, gap = argc > 5 ? atoi(argv[5]) : 1000;
		unsigned long first = ll[0].place / (FRAME_WORDS * 32), last = first;
		uint32_t far = ll[0].far;
		for (int i = 0; i < n; i++) {
			unsigned long frame = ll[i].place / (FRAME_WORDS * 32);
			if (frame < first) { first = frame; far = ll[i].far; }
			if (frame > last) last = frame;
		}
		const int start = 118;
		int nw = start + (int)(last - first + 1) * FRAME_WORDS;
		uint32_t *w = malloc(nw * 4);
		for (int r = 0; r < reads; r++) {
			if (r) usleep(gap * 1000);
			double t = capture_and_read(far, w, nw);
			char text[4097]; unsigned long long value = 0;
			for (int i = 0; i < n; i++) {
				unsigned long at = ll[i].place - first * FRAME_WORDS * 32;
				int bit = !((w[start + at / 32] >> (at % 32)) & 1);
				text[i] = bit ? '1' : '0';
				if (i < 64) value |= (unsigned long long)bit << i;
			}
			text[n] = 0;
			printf("read %d: t=%.3f s  %s  0x%llx\n", r, t, text, value);
		}
		printf("STAT = 0x%08x\n", read_reg(R_STAT));
	} else if (!strcmp(argv[2], "capdiff") && argc > 4) {
		// capture + read n frames from far twice, gap ms apart; print the words that differ
		uint32_t far = strtoul(argv[3], NULL, 0); int nf = atoi(argv[4]), gap = argc > 5 ? atoi(argv[5]) : 100;
		int nw = (nf + 2) * FRAME_WORDS;
		uint32_t *a = malloc(nw * 4), *b = malloc(nw * 4);
		capture_and_read(far, a, nw);
		usleep(gap * 1000);
		capture_and_read(far, b, nw);
		int nd = 0, nz = 0;
		for (int k = 0; k < nw; k++) {
			nz += a[k] != 0;
			if (a[k] != b[k]) { nd++; printf("word %5d (pipeline-corrected frame %d + %2d): %08x -> %08x\n", k, (k - 118) / FRAME_WORDS, (k - 118) % FRAME_WORDS, a[k], b[k]); }
		}
		printf("%d of %d words differ; %d nonzero\n", nd, nw, nz);
	} else if (!strcmp(argv[2], "sample") && argc > 3) {
		// boundary-scan SAMPLE (IR 000001): snapshots the pins without driving them;
		// prints the boundary-register bits that changed between snapshots
		int nb = atoi(argv[3]), reads = argc > 4 ? atoi(argv[4]) : 8, gap = argc > 5 ? atoi(argv[5]) : 50;
		uint8_t **snap = malloc(reads * sizeof *snap);
		for (int r = 0; r < reads; r++) {
			if (r) usleep(gap * 1000);
			snap[r] = calloc(nb, 1);
			shift_ir(0x01);
			tmsseq("100");                  // Shift-DR
			bits(NULL, NULL, snap[r], nb);  // TDI 0; ends still in Shift-DR
			tmsseq("110");                  // Exit1, Update, Run-Test/Idle
		}
		int changed = 0;
		for (int i = 0; i < nb; i++) {
			int c = 0; for (int r = 1; r < reads; r++) c |= snap[r][i] != snap[0][i];
			if (!c) continue;
			changed++;
			printf("bit %5d:", i); for (int r = 0; r < reads; r++) printf(" %d", snap[r][i]); printf("\n");
		}
		long ones = 0; for (int i = 0; i < nb; i++) ones += snap[0][i];
		int last1 = -1; for (int i = 0; i < nb; i++) if (snap[0][i]) last1 = i;
		printf("%d of %d bits changed over %d snapshots %d ms apart; first snapshot has %ld ones, last one at bit %d\n", changed, nb, reads, gap, ones, last1);
		shift_ir(0x3f);
	} else { fprintf(stderr, "bad command\n"); rc = 1; }
	close_cable();
	return rc;
}
