// SFU (special function unit) of one sub-core: multi-cycle integer functions on 8 lanes in parallel.
//   DIV   rd = a / b   (unsigned; b == 0 gives 0xFFFFFFFF)       32 cycles, restoring division, 1 bit per cycle
//   REM   rd = a % b   (unsigned; b == 0 gives a)                 32 cycles, same divider
//   (the divide-by-zero results come out of the restoring divider naturally; no special case is needed)
//   ISQRT rd = floor(sqrt(a)) (a unsigned)                        16 cycles, digit by digit, 2 bits per cycle
// One instruction at a time: ex_ready is low while busy or while the previous result waits for the
// register file. Result through wb_* (valid/ready), lanes outside the mask are not written.
module sfu
  import mgpu_pkg::*;
#(
  parameter int NW = 4,
  localparam int WW = $clog2(NW)
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             ex_valid,
  output logic             ex_ready,
  input  logic [WW-1:0]    ex_warp,
  input  logic [31:0]      ex_instr,
  input  logic [LANES-1:0] ex_mask,
  input  logic [31:0]      ex_a [LANES],
  input  logic [31:0]      ex_b [LANES],
  output logic             wb_valid,
  input  logic             wb_ready,
  output logic [WW-1:0]    wb_warp,
  output logic [3:0]       wb_rd,
  output logic [LANES-1:0] wb_mask,
  output logic [31:0]      wb_data [LANES],
  output logic             busy
);
  logic        run;
  logic [5:0]  cnt;
  logic [5:0]  op;
  logic [32:0] rem [LANES];
  logic [31:0] quo [LANES];
  logic [31:0] den [LANES];
  logic [31:0] sq_op [LANES], sq_res [LANES], sq_one;

  assign busy = run || wb_valid;
`ifdef BUG_BUSY_ACCEPT
  assign ex_ready = !run;
`else
  assign ex_ready = !run && (!wb_valid || wb_ready);
`endif

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run <= 1'b0;
      wb_valid <= 1'b0;
      cnt <= '0;
    end else begin
      if (wb_valid && wb_ready) wb_valid <= 1'b0;
      if (ex_valid && ex_ready) begin
        run     <= 1'b1;
        op      <= f_op(ex_instr);
        wb_warp <= ex_warp;
        wb_rd   <= f_rd(ex_instr);
        wb_mask <= ex_mask;
`ifdef BUG_ISQRT_ITER
        cnt     <= (f_op(ex_instr) == OP_ISQRT) ? 6'd15 : 6'd32;
`else
        cnt     <= (f_op(ex_instr) == OP_ISQRT) ? 6'd16 : 6'd32;
`endif
        sq_one  <= 32'h4000_0000;
        for (int l = 0; l < LANES; l++) begin
          rem[l] <= '0; quo[l] <= ex_a[l]; den[l] <= ex_b[l];
          sq_op[l] <= ex_a[l]; sq_res[l] <= '0;
        end
      end else if (run) begin
        if (op == OP_ISQRT) begin
          for (int l = 0; l < LANES; l++)
            if (sq_op[l] >= sq_res[l] + sq_one) begin
              sq_op[l]  <= sq_op[l] - (sq_res[l] + sq_one);
              sq_res[l] <= (sq_res[l] >> 1) + sq_one;
            end else sq_res[l] <= sq_res[l] >> 1;
          sq_one <= sq_one >> 2;
        end else begin
          for (int l = 0; l < LANES; l++) begin
            logic [32:0] r;
            r = {rem[l][31:0], quo[l][31]};
            if (r >= {1'b0, den[l]}) begin
              rem[l] <= r - {1'b0, den[l]};
              quo[l] <= {quo[l][30:0], 1'b1};
            end else begin
              rem[l] <= r;
              quo[l] <= {quo[l][30:0], 1'b0};
            end
          end
        end
        cnt <= cnt - 1;
        if (cnt == 1) begin
          run <= 1'b0;
          wb_valid <= 1'b1;
        end
      end
    end
  end

  // results come straight from the iteration registers once finished
  always_comb
    for (int l = 0; l < LANES; l++)
      case (op)
`ifdef BUG_DIV0
        OP_DIV:  wb_data[l] = (den[l] == 0) ? 32'h0 : quo[l];
`else
        OP_DIV:  wb_data[l] = quo[l];      // b == 0: every step "subtracts" 0, so the quotient is all ones
`endif
        OP_REM:  wb_data[l] = rem[l][31:0];
        default: wb_data[l] = sq_res[l];
      endcase
endmodule
