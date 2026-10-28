# Channelizer test vectors

Bit-exact reference values for the FFT testbench (`../tb_fft.v`), from
the fixed-point model in the server repo (web888-ng):

```sh
cargo run --release -p web888-dsp --example pfbvectors -- DIR 2
```

`meta.txt` lists the sizes and widths. Kept here, for two frames:
`packed.hex` (the FFT input), `fft.hex` (its bit-reversed output),
`bins.hex` (the split stage's N + 1 bins a frame), and the twiddles
`tw.hex` and `split_tw.hex`. Used by `tb_fft.v` and `tb_split.v`. The
example also writes the ADC input and coefficients (`adc.hex`,
`coefs.hex`, about 400 kB), for the polyphase FIR's test.
