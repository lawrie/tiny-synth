`ifndef __TINY_SYNTH_MIDI_PLAYER__
`define __TINY_SYNTH_MIDI_PLAYER__

/* Using some slimmed-down versions of the voice code
   so that we can fit more voices in the budget */
`include "../../hdl/tiny-synth-all.vh"
`include "filter_tables.vh"

/* Clifford Wolf's simpleuart */
`include "simpleuart.vh"

/* .. and a wrapper for it that handles framing incoming messages into MIDI commands */
`include "midi_uart.vh"

/* Rotary encoder based on fpga4fun example */
`include "rotary.vh"

module midi_player #(
  parameter SAMPLE_BITS = 12,
`ifdef blackice
  parameter NUM_LEDS = 4,
`else
  parameter NUM_LEDS = 1,
`endif
  parameter NUM_SWITCHES = 8,
  parameter NUM_DIALS = 5
) (
  input wire clk,
  input wire serial_rx,
  input [NUM_SWITCHES-1:0] switches,
  input [NUM_DIALS-1:0] quadA,
  input [NUM_DIALS-1:0] quadB,
  output [NUM_LEDS-1:0] led,
  output signed [SAMPLE_BITS-1:0] audio_data
);

  /* incoming midi data */
  reg [7:0] midi_uart_data;
  reg midi_byte_clk;
  reg midi_event_valid;
  wire [7:0] midi_command;
  wire [6:0] midi_parameter_1;
  wire [6:0] midi_parameter_2;
  wire midi_event_ack;

  assign led = switches[3:0];

  reg serial_tx;

  midi_uart midi_uart(
    .clk(clk),
    .serial_rx(serial_rx), .serial_tx(serial_tx),
    .midi_event_valid(midi_event_valid),
    .midi_command(midi_command),
    .midi_parameter_1(midi_parameter_1),
    .midi_parameter_2(midi_parameter_2),
    .midi_event_ack(midi_event_ack)
  );

  /* CLOCK GENERATION; generate 1MHz clock for voice oscillators, and 44100Hz clock for sample output */
  wire ONE_MHZ_CLK;
  clock_divider #(.DIVISOR(16)) mhz_clk_divider(.cin(clk), .cout(ONE_MHZ_CLK));

  localparam SAMPLE_CLK_FREQ = 250000;

  // divide main clock down to 44100Hz for sample output (note this clock will have
  // a bit of jitter because 44.1kHz doesn't go evenly into 16MHz).
  wire SAMPLE_CLK;
  clock_divider #(
    .DIVISOR((16000000/SAMPLE_CLK_FREQ))
  ) sample_clk_divider(.cin(clk), .cout(SAMPLE_CLK));

  // number of voices to use
  // if you modify this, you'll also need to manually update the
  // mixing function below
  localparam NUM_VOICES = 4;

  // individual voices are mixed into here..
  // output is wider than a single voice, and gets "clamped" (or "saturated") into clamped_voice_out.
  reg signed [SAMPLE_BITS+$clog2(NUM_VOICES)-1:0] raw_combined_voice_out;
  wire signed [SAMPLE_BITS-1:0] clamped_voice_out;
  wire signed [SAMPLE_BITS-1:0] out_lp;
  wire signed [SAMPLE_BITS-1:0] out_hp;
  wire signed [SAMPLE_BITS-1:0] out_bp;
  wire signed [SAMPLE_BITS-1:0] out_notch;

  localparam signed MAX_SAMPLE_VALUE = (2**(SAMPLE_BITS-1))-1;
  localparam signed MIN_SAMPLE_VALUE = -(2**(SAMPLE_BITS-1));

  assign  clamped_voice_out = (raw_combined_voice_out > MAX_SAMPLE_VALUE)
                            ? MAX_SAMPLE_VALUE
                            : ((raw_combined_voice_out < MIN_SAMPLE_VALUE)
                              ? MIN_SAMPLE_VALUE
                              : raw_combined_voice_out[SAMPLE_BITS-1:0]);


  reg [NUM_VOICES-1:0] voice_gate;  /* MIDI gates */
  reg [15:0] voice_frequency[0:NUM_VOICES-1];  /* frequency of the voice */
  reg [6:0] voice_note[0:NUM_VOICES-1];        /* midi note that is playing on this voice */
  wire signed[SAMPLE_BITS-1:0] voice_samples[0:NUM_VOICES-1];  // samples for each voice

  // MIXER: this adds the output from the 8 voices together
  always @(posedge SAMPLE_CLK) begin
    raw_combined_voice_out <= (voice_samples[0]+voice_samples[1]+voice_samples[2]+voice_samples[3])>>>1;
  end

  // changeable voice parameters
  reg [3:0] attack;
  reg [3:0] decay;
  reg [3:0] sustain;
  reg [3:0] rel;

  reg [1:0] midi_wave_select;
  reg [7:0] pulse_width;

  reg [6:0] midi_filter_freq = 64;
  reg [6:0] midi_filter_q = 64;

  reg [3:0] voice_waveform_enable;

  assign voice_waveform_enable = switches[3:0];

  reg [5:0] sustain1;
  assign sustain = sustain1[5:2];
  rotary #(.BITS(6), .INC(1), .INIT(16)) rot1 (.clk(clk), .quadA(quadA[0]), .quadB(quadB[0]), .value(sustain1));

  reg [5:0] attack1;
  assign attack = attack1[5:2];
  rotary #(.BITS(6), .INC(1), .INIT(16)) rot2 (.clk(clk), .quadA(quadA[1]), .quadB(quadB[1]), .value(attack1));

  reg [5:0] decay1;
  assign decay = decay1[5:2];
  rotary #(.BITS(6), .INC(1), .INIT(16)) rot3 (.clk(clk), .quadA(quadA[2]), .quadB(quadB[2]), .value(decay1));

  reg [5:0] rel1;
  assign rel = rel1[5:2];
  rotary #(.BITS(6), .INC(1), .INIT(16)) rot4 (.clk(clk), .quadA(quadA[3]), .quadB(quadB[3]), .value(rel1));

  reg [9:0] pulse_width1;
  assign pulse_width = pulse_width1[9:2];
  rotary #(.BITS(10), .INC(1), .INIT(384)) rot5 (.clk(clk), .quadA(quadA[4]), .quadB(quadB[4]), .value(pulse_width1));

  reg signed [17:0] filter_f;
  reg signed [17:0] filter_q1;

  f_table filter_f_lookup(.clk(SAMPLE_CLK), .val(midi_filter_freq), .result(filter_f));
  q1_table filter_q1_lookup(.clk(SAMPLE_CLK), .val(midi_filter_q), .result(filter_q1));

  // state variable filter
  filter_svf_pipelined #(.SAMPLE_BITS(SAMPLE_BITS))
  filter(
    .clk(ONE_MHZ_CLK),  /* needs to be at least 4x SAMPLE_CLK */
    .sample_clk(SAMPLE_CLK),
    .in(clamped_voice_out),
    .out_highpass(out_hp),
    .out_lowpass(out_lp),
    .out_bandpass(out_bp),
    .out_notch(out_notch),
    .F(filter_f),
    .Q1(filter_q1)
  );

//  assign audio_data = clamped_voice_out;
  assign audio_data =

   (switches[7:4] == 0) ? clamped_voice_out
   : switches[4] ? out_lp
   : switches[5] ? out_hp
   : switches[6] ? out_bp
   : out_notch;

  generate
    genvar i;
    /* generate some voices and wire them to the per-MIDI-note gates */
    for (i=0; i<NUM_VOICES; i=i+1)
    begin : voices
      voice #(
        .OUTPUT_BITS(SAMPLE_BITS),
      ) voice (
        .main_clk(ONE_MHZ_CLK), .sample_clk(SAMPLE_CLK), .tone_freq(voice_frequency[i]), .rst(1'b0), .test(1'b0),
        .waveform_enable(voice_waveform_enable),
        .en_ringmod(1'b0), .ringmod_source(1'b0),
        .en_sync(1'b0), .sync_source(1'b0),
        .dout(voice_samples[i]),
        .gate(voice_gate[i]),
        .attack(attack), .decay(decay), .sustain(sustain), .rel(rel),
        .pulse_width({pulse_width, 4'b0000})
      );
    end
  endgenerate

  `include "midi_note_to_tone_freq.vh"

  reg [1:0] next_voice;

  integer voice_idx;
  wire [15:0] tone_freq;
  assign tone_freq = midi_note_to_tone_freq(midi_parameter_1);

  /* handle read and acknowledgement of UART data, and clocking it in to the MIDI framer */
  always @(posedge clk) begin : midi_note_processor
    if (midi_event_valid && !midi_event_ack) begin
      // acknowledge the incoming MIDI event (this will automatically clear the _event_valid flag)
      midi_event_ack <= 1'b1;

      case (midi_command[7:4])
        // note on ; find an idle voice and assign this note to it (and gate it on)
        // the long chain below is because yosys doesn't support the "disable" statement.
        4'h9: begin
                voice_note[next_voice] <= midi_parameter_1;
                voice_frequency[next_voice] <= tone_freq;
                voice_gate[next_voice] <= 1'b1;
                voice_gate[next_voice+1] <= 1'b0; // get next voice ready for use by gating it off
                next_voice <= next_voice + 1;
              end
        // note off ; find the voice playing this note, and gate it off.
        4'h8: begin
                for (voice_idx = 0; voice_idx < NUM_VOICES; voice_idx = voice_idx + 1) begin
                  if (voice_note[voice_idx] == midi_parameter_1) begin
                    voice_note[voice_idx] <= 0;
                    voice_gate[voice_idx] <= 1'b0;
                  end
                end
              end
        // controller update; update voice parameters appropriately
        4'hb: begin
              case (midi_parameter_1)
                7'h01:  midi_filter_freq <= midi_parameter_2[6:0]; /* track pad - modulation*/
              endcase
            end
      4'he: midi_filter_q <= midi_parameter_2[6:0]; // track pad with button - pitch bend

      endcase
    end else begin
      // no event to acknowledge, so clear ack flag
      midi_event_ack <= 1'b0;
    end

  end

endmodule

`endif
