`ifndef __TINY_SYNTH_ROTARY__
`define __TINY_SYNTH_ROTARY__

module rotary(
  input clk,
  input quadA,
  input quadB,
  output [11:0] value
);

parameter INC = 32;

reg [2:0] quadAr, quadBr;

always @(posedge clk) begin
  quadAr <= {quadAr[1:0], quadA};
  quadBr <= {quadBr[1:0], quadB};
  if (quadAr[2] ^ quadAr[1] ^ quadBr[2] ^ quadBr[1]) begin
    if (quadAr[2] ^ quadBr[1]) begin
      if (~&value) value  <= value + INC;
    end else begin
        if (|value) value <= value - INC;
    end
  end 
end

endmodule
`endif

