/* The primes below 2048 by a sieve of Eratosthenes, in rv32i (adds and
 * shifts only: no multiplier), their count (309) written to the result
 * register; then the LED toggled forever, about once a second. */
#define LED (*(volatile unsigned *)0x10000000)
#define RESULT (*(volatile unsigned *)0x10000004)
#define N 2048
#ifndef DELAY
#define DELAY 1000000
#endif

static unsigned char composite[N];

int main(void)
{
    unsigned count = 0;
    for (unsigned i = 2; i < N; i++) {
        if (composite[i])
            continue;
        count++;
        for (unsigned j = i + i; j < N; j += i)
            composite[j] = 1;
    }
    RESULT = count;
    for (unsigned on = 1;; on ^= 1) {
        LED = on;
        for (volatile unsigned k = 0; k < DELAY; k++)
            ;
    }
}
