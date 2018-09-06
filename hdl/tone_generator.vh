`ifndef __TINY_SYNTH_TONE_GENERATOR_AGGREGATE__
`define __TINY_SYNTH_TONE_GENERATOR_AGGREGATE__

`include "tone_generator_saw.vh"
`include "tone_generator_pulse.vh"
`include "tone_generator_triangle.vh"
`include "tone_generator_noise.vh"

/* ================================
 * Phase-accumulator tone-generator
 * ================================
 *
 * This module aggregates the other tone generators together.
 *
 * It houses the accumulator and the logic for incrementing it
 * at a given frequency.
 *
 * It allows individual tone generators to be selected and logically
 * "ANDed" into the output stream.
 *
 * It also has provision for syncing oscillators together based on
 * when they overflow, and proving the accumulator MSB for ring
 * modulation purposes.
 */
module tone_generator #(
  parameter FREQ_BITS = 16,
  parameter PULSEWIDTH_BITS = 12,
  parameter OUTPUT_BITS = 12,
  parameter ACCUMULATOR_BITS = 24
)
(
  input [FREQ_BITS-1:0] tone_freq,
  input [PULSEWIDTH_BITS-1:0] pulse_width,
  input main_clk,
  input sample_clk,
  input rst,
  input test,
  output wire signed [OUTPUT_BITS-1:0] dout,
  output wire accumulator_msb,
  output wire sync_trigger_out,

  input wire en_ringmod,
  input wire ringmod_source,

  input wire en_sync,
  input wire sync_source,

  input en_noise,
  input en_pulse,
  input en_triangle,
  input en_saw);

  reg [ACCUMULATOR_BITS-1:0] accumulator;
  reg [ACCUMULATOR_BITS-1:0] prev_accumulator;

  wire [OUTPUT_BITS-1:0] noise_dout;
  tone_generator_noise #(
    .OUTPUT_BITS(OUTPUT_BITS)
  ) noise(.clk(accumulator[19]), .rst(rst || test), .dout(noise_dout));

  wire [OUTPUT_BITS-1:0] triangle_dout;
  tone_generator_triangle #(
      .ACCUMULATOR_BITS(ACCUMULATOR_BITS),
      .OUTPUT_BITS(OUTPUT_BITS)
  ) triangle_generator (
      .accumulator(accumulator),
      .dout(triangle_dout),
      .en_ringmod(en_ringmod),
      .ringmod_source(ringmod_source)
    );

  wire [OUTPUT_BITS-1:0] saw_dout;
  tone_generator_saw  #(
      .ACCUMULATOR_BITS(ACCUMULATOR_BITS),
      .OUTPUT_BITS(OUTPUT_BITS)
    ) saw(
      .accumulator(accumulator),
      .dout(saw_dout)
    );

  wire [OUTPUT_BITS-1:0] pulse_dout;
  tone_generator_pulse  #(
      .ACCUMULATOR_BITS(ACCUMULATOR_BITS),
      .OUTPUT_BITS(OUTPUT_BITS),
      .PULSEWIDTH_BITS(PULSEWIDTH_BITS)
    ) pulse(
      .accumulator(accumulator),
      .dout(pulse_dout),
      .pulse_width(pulse_width)
    );

  reg [OUTPUT_BITS-1:0] dout_tmp;

  always @(posedge main_clk) begin
    if ((en_sync && sync_source) || test)
      begin
        prev_accumulator <= 0;
        accumulator <= 0;
      end
    else
      begin
        prev_accumulator <= accumulator;
        accumulator <= accumulator + tone_freq;
      end
  end

  // ref ReSID:
  // msb_rising = !(accumulator_prev & 0x800000) && (accumulator & 0x800000);
  // if (msb_rising && sync_dest->sync && !(sync && sync_source->msb_rising)) {
  //   sync_dest->accumulator = 0;
  // }
  assign sync_trigger_out = (!(prev_accumulator & 24'h800000) && (accumulator & 24'h800000));
                        //&& (!(en_sync && sync_source));

  assign accumulator_msb = accumulator[ACCUMULATOR_BITS-1];

  always @(posedge sample_clk) begin
    dout_tmp = (2**OUTPUT_BITS)-1;
    if (en_noise)
      dout_tmp = dout_tmp & noise_dout;
    if (en_saw)
      dout_tmp = dout_tmp & saw_dout;
    if (en_triangle)
      dout_tmp = dout_tmp & triangle_dout;
    if (en_pulse)
      dout_tmp = dout_tmp & pulse_dout;
  end

  // convert dout value to a signed value
  assign dout = dout_tmp ^ (2**(OUTPUT_BITS-1));

endmodule

`endif
