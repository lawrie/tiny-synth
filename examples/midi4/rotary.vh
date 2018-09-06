`ifndef __TINY_SYNTH_ROTARY__
`define __TINY_SYNTH_ROTARY__

module rotary(
  input clk,
  input quadA,
  input quadB,
  output [BITS-1:0] value
);

parameter INC = 32;
parameter BITS = 12;
parameter INIT = 0;

initial value <= INIT;

reg [2:0] quadAr, quadBr;

always @(posedge clk) begin
  quadAr <= {quadAr[1:0], quadA};
  quadBr <= {quadBr[1:0], quadB};
  if (quadAr[2] ^ quadAr[1] ^ quadBr[2] ^ quadBr[1]) begin
    if (quadAr[2] ^ quadBr[1]) begin
      if (value + INC <= {BITS{1'b1}}) value  <= value + INC;
    end else begin
        if (value >= INC) value <= value - INC;
    end
  end 
end

endmodule
`endif

