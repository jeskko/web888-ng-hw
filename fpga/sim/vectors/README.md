# Channelizer test vectors

Bit-exact reference values for the FFT testbench (`../tb_fft.v`), from
the fixed-point model in the server repo (web888-ng):

```sh
cargo run --release -p web888-dsp --example pfbvectors -- DIR 2
```

`meta.txt` lists the sizes and widths. Kept here: `packed.hex` (the FFT
input, two frames), `fft.hex` (its bit-reversed output) and `tw.hex`
(the twiddles). The example also writes the ADC input, coefficients,
split twiddles and bins, for the polyphase FIR and split stage tests.
