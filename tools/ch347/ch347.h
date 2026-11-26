// CH347T (mode 3, 1a86:55dd) JTAG primitives, shared by bypass.c and cfg.c.
// Only the read-back commands are used (0xd2 bits, 0xd4 bytes): every command's
// reply is read, which is what keeps the adapter from dropping data (its
// write-only 0xd3 path, as openFPGALoader drives it, loses bits).
#ifndef CH347_H
#define CH347_H
#include <libusb.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#define EP_OUT 0x06
#define EP_IN  0x86
#define TCK 1
#define TMS 2
#define TDI 16
static libusb_device_handle *h;

static double now(void) { struct timeval t; gettimeofday(&t, NULL); return t.tv_sec + t.tv_usec / 1e6; }

static void xfer(uint8_t *o, int ol, uint8_t *in, int il) {
	int a, r;
	if ((r = libusb_bulk_transfer(h, EP_OUT, o, ol, &a, 2000)) || a != ol) { fprintf(stderr, "write fail %d %d/%d\n", r, a, ol); exit(2); }
	int got = 0;
	while (got < il) {
		if ((r = libusb_bulk_transfer(h, EP_IN, in + got, il - got, &a, 2000))) { fprintf(stderr, "read fail %d\n", r); exit(2); }
		got += a;
	}
}
// clock n bits; tms/tdi/tdo one byte per bit (NULL = all zero / discard)
static void bits(const uint8_t *tms, const uint8_t *tdi, uint8_t *tdo, int n) {
	while (n > 0) {
		int k = n > 250 ? 250 : n;
		uint8_t o[512], in[512]; int p = 3;
		uint8_t v = 0;
		for (int i = 0; i < k; i++) {
			v = (tms && tms[i] ? TMS : 0) | (tdi && tdi[i] ? TDI : 0);
			o[p++] = v; o[p++] = v | TCK;
		}
		o[p++] = v;
		o[0] = 0xd2; o[1] = (p-3) & 0xff; o[2] = (p-3) >> 8;
		xfer(o, p, in, k + 3);
		if (in[0] != 0xd2) { fprintf(stderr, "bad bits reply %02x\n", in[0]); exit(2); }
		if (tdo) { for (int i = 0; i < k; i++) tdo[i] = in[3+i] & 1; tdo += k; }
		if (tms) tms += k;
		if (tdi) tdi += k;
		n -= k;
	}
}
static void tmsseq(const char *s) {
	uint8_t t[64]; int n = strlen(s);
	for (int i = 0; i < n; i++) t[i] = s[i] == '1';
	bits(t, NULL, NULL, n);
}
// from Run-Test/Idle: shift a 6-bit IR, return its capture, end in Run-Test/Idle
static int shift_ir(int ir) {
	uint8_t t[6] = {0,0,0,0,0,1}, d[6], q[6]; int cap = 0;
	for (int i = 0; i < 6; i++) d[i] = (ir >> i) & 1;
	tmsseq("1100");
	bits(t, d, q, 6);
	tmsseq("10");
	for (int i = 0; i < 6; i++) cap |= q[i] << i;
	return cap;
}
static void rti_clocks(int n) {
	while (n > 0) { int k = n > 250 ? 250 : n; bits(NULL, NULL, NULL, k); n -= k; }
}

// ---- pipelined byte shifting (in Shift-DR/IR; TMS stays low) ----
// tx (NULL = zeros) is shifted LSB first per byte; rx (NULL = discard) gets TDO.
// Commands of `chunk` bytes, at most `depth` of them sent but not yet answered.
struct stream {
	const uint8_t *tx; uint8_t *rx; long n; int chunk; int depth;
	sem_t credits; volatile int error;
};
static void *stream_reader(void *arg) {
	struct stream *s = arg;
	uint8_t buf[512]; int have = 0, need_hdr = 1; long body = 0, done = 0;
	long cmd_len = 0;
	while (done < s->n && !s->error) {
		int a, r = libusb_bulk_transfer(h, EP_IN, buf, sizeof buf, &a, 3000);
		if (r) { fprintf(stderr, "stream read fail %d at %ld\n", r, done); s->error = 1; break; }
		int p = 0;
		while (p < a) {
			if (need_hdr) {
				static uint8_t hdr[3];
				while (have < 3 && p < a) hdr[have++] = buf[p++];
				if (have < 3) break;
				cmd_len = hdr[1] | hdr[2] << 8;
				long expect = s->n - done < s->chunk ? s->n - done : s->chunk;
				if (hdr[0] != 0xd4 || cmd_len != expect) {
					fprintf(stderr, "stream: bad reply header %02x len %ld (expected %ld) at %ld\n", hdr[0], cmd_len, expect, done);
					s->error = 1; break;
				}
				need_hdr = 0; body = 0;
			} else {
				int k = a - p < cmd_len - body ? a - p : cmd_len - body;
				if (s->rx) memcpy(s->rx + done + body, buf + p, k);
				p += k; body += k;
				if (body == cmd_len) {
					done += cmd_len; need_hdr = 1; have = 0;
					sem_post(&s->credits);
				}
			}
		}
	}
	return NULL;
}
static int jtag_stream(const uint8_t *tx, uint8_t *rx, long n, int chunk, int depth) {
	struct stream s = { tx, rx, n, chunk, depth, {{0}}, 0 };
	sem_init(&s.credits, 0, depth);
	pthread_t th; pthread_create(&th, NULL, stream_reader, &s);
	uint8_t *o = malloc(chunk + 3);
	for (long done = 0; done < n && !s.error; ) {
		int k = n - done < chunk ? n - done : chunk;
		sem_wait(&s.credits);
		o[0] = 0xd4; o[1] = k & 0xff; o[2] = k >> 8;
		if (tx) memcpy(o + 3, tx + done, k); else memset(o + 3, 0, k);
		int a, r = libusb_bulk_transfer(h, EP_OUT, o, k + 3, &a, 3000);
		if (r || a != k + 3) { fprintf(stderr, "stream write fail %d %d/%d at %ld\n", r, a, k + 3, done); s.error = 1; break; }
		done += k;
	}
	pthread_join(th, NULL);
	free(o); sem_destroy(&s.credits);
	return s.error ? -1 : 0;
}

static const double ch347_hz[8] = {468750, 937500, 1875000, 3750000, 7500000, 15000000, 30000000, 60000000};
static void open_cable(int factor) {
	libusb_init(NULL);
	h = libusb_open_device_with_vid_pid(NULL, 0x1a86, 0x55dd);
	if (!h) { fprintf(stderr, "open fail\n"); exit(1); }
	libusb_set_auto_detach_kernel_driver(h, 1);
	if (libusb_claim_interface(h, 2)) { fprintf(stderr, "claim fail\n"); exit(1); }
	uint8_t o[16], in[512]; int a;
	while (libusb_bulk_transfer(h, EP_IN, in, 512, &a, 100) == 0) ;   // drain stale replies
	memset(o, 0, 16); o[0] = 0xd0; o[1] = 6; o[4] = factor;
	if (libusb_bulk_transfer(h, EP_OUT, o, 9, &a, 2000) || a != 9) { fprintf(stderr, "clk write fail\n"); exit(1); }
	if (libusb_bulk_transfer(h, EP_IN, in, 512, &a, 2000) || a != 4) { fprintf(stderr, "clk reply fail (%d bytes)\n", a); exit(1); }
	if (in[0] != 0xd0 || in[3] != 0) { fprintf(stderr, "clk fail\n"); exit(1); }
	tmsseq("11111"); tmsseq("0");
}
static void close_cable(void) {
	tmsseq("11111");
	libusb_release_interface(h, 2); libusb_close(h); libusb_exit(NULL);
}
#endif
