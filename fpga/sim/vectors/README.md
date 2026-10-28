# Channelizer test vectors

Bit-exact reference values for the FFT testbench (`../tb_fft.v`), from
the fixed-point model in the server repo (web888-ng):

```sh
cargo run --release -p web888-dsp --example pfbvectors -- DIR 2
```

`meta.txt` lists the sizes and widths. Kept here, for two frames:
`adc.hex` (the input), `packed.hex` (the FIR's output, the FFT's input),
`fft.hex` (its bit-reversed output) and `bins.hex` (the split stage's
N + 1 bins a frame). Used by `tb_fir.v`, `tb_fft.v`, `tb_split.v` and
`tb_chain.v`. The ROM tables the RTL needs (coefficients, twiddles) come
from the same run and live in `../../rtl/gen/pfb_*.mem`.
