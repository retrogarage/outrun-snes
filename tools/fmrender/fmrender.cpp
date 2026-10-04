// fmrender: drive a ymfm YM2151 from a tiny text script and dump raw audio.
//   fmrender <clock_hz> <out.raw>   (script on stdin)
//   W rr vv   write register rr (hex) = vv (hex)
//   G n       generate n samples at the native rate (clock/64), append mono int16 (L+R)/2
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "ymfm_opm.h"

class intf : public ymfm::ymfm_interface {};

int main(int argc, char** argv)
{
    if (argc < 3) { fprintf(stderr, "usage: fmrender clock out.raw < script\n"); return 1; }
    uint32_t clock = strtoul(argv[1], 0, 0);
    FILE* out = fopen(argv[2], "wb");
    intf i;
    ymfm::ym2151 chip(i);
    chip.reset();
    char line[256];
    while (fgets(line, sizeof line, stdin)) {
        if (line[0] == 'W') {
            unsigned r, v;
            sscanf(line + 1, "%x %x", &r, &v);
            chip.write_address(r);
            chip.write_data(v);
        } else if (line[0] == 'G') {
            long n = strtol(line + 1, 0, 0);
            for (long k = 0; k < n; k++) {
                ymfm::ym2151::output_data o;
                chip.generate(&o, 1);
                int s = (o.data[0] + o.data[1]) / 2;
                if (s > 32767) s = 32767; if (s < -32768) s = -32768;
                int16_t v = s;
                fwrite(&v, 2, 1, out);
            }
        }
    }
    fclose(out);
    printf("%u\n", chip.sample_rate(clock));
    return 0;
}
