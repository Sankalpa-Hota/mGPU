// Register file + operand collector of one sub-core.
// Storage: NW warps x 16 registers x LANES lanes x 32 bits, organised as 4 banks; register r of warp w lives
// in bank (r + w) % 4, so the same register of different warps is spread over the banks.
// Each bank has one read port and one write port per cycle. r0 always reads as 0 and is never written.
//
// Operand collector (one entry): accepts an issued instruction, reads operand A (rs1) and operand B
// (rs2, or rd for stores and branches) - in one cycle, or two if both are in the same bank - then offers the
// instruction to its execution unit: ALU (also BEQ/BNE/JMP/EXIT), SFU, LSU, or the barrier unit (BAR).
// Writeback: NWB ports; per bank, the lowest-numbered port wins; a write only changes the lanes in its mask.
module regfile_collector
  import mgpu_pkg::*;
#(
  parameter int NW  = 4,
  parameter int NWB = 3,
  localparam int WW = $clog2(NW)
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [NW-1:0]    wl_mask,       // launched warps: their registers are cleared to 0
  input  logic             is_valid,
  output logic             is_ready,
  input  logic [WW-1:0]    is_warp,
  input  logic [31:0]      is_instr,
  input  logic [31:0]      is_pc,
  input  logic [LANES-1:0] is_mask,
  output logic             ex_valid,
  output logic [1:0]       ex_unit,       // 0 ALU, 1 SFU, 2 LSU, 3 barrier
  input  logic [3:0]       ex_ready,      // one ready per unit
  output logic [WW-1:0]    ex_warp,
  output logic [31:0]      ex_instr,
  output logic [31:0]      ex_pc,
  output logic [LANES-1:0] ex_mask,
  output logic [31:0]      ex_a [LANES],
  output logic [31:0]      ex_b [LANES],
  input  logic [NWB-1:0]   wb_valid,
  output logic [NWB-1:0]   wb_ready,
  input  logic [WW-1:0]    wb_warp [NWB],
  input  logic [3:0]       wb_rd   [NWB],
  input  logic [LANES-1:0] wb_mask [NWB],
  input  logic [31:0]      wb_data [NWB][LANES]
);
  logic [31:0] rf [NW][NREG][LANES];

  function automatic logic [1:0] bank(logic [WW-1:0] w, logic [3:0] r);
    return 2'(r + w);
  endfunction

  // ---------------- collector entry
  logic             occ, need_a, need_b;
  logic [WW-1:0]    c_warp;
  logic [31:0]      c_instr, c_pc;
  logic [LANES-1:0] c_mask;
  logic [31:0]      c_a [LANES];
  logic [31:0]      c_b [LANES];

  logic [3:0] ra, rb;
  assign ra = f_rs1(c_instr);
  assign rb = src_b(c_instr);
  logic rd_a, rd_b;
  assign rd_a = occ && need_a;
`ifdef BUG_BANK_CONFLICT
  assign rd_b = occ && need_b;
`else
  assign rd_b = occ && need_b && !(rd_a && bank(c_warp, ra) == bank(c_warp, rb));
`endif

  logic [1:0] unit;
  always_comb
    case (unit_of(f_op(c_instr)))
      U_SFU:   unit = 2'd1;
      U_LSU:   unit = 2'd2;
      default: unit = (f_op(c_instr) == OP_BAR) ? 2'd3 : 2'd0;
    endcase

  assign ex_valid = occ && !need_a && !need_b;
  assign ex_unit  = unit;
  assign ex_warp  = c_warp;
  assign ex_instr = c_instr;
  assign ex_pc    = c_pc;
  assign ex_mask  = c_mask;
  assign ex_a     = c_a;
  assign ex_b     = c_b;

  logic ex_fire;
  assign ex_fire  = ex_valid && ex_ready[unit];
  assign is_ready = !occ || ex_fire;

  // ---------------- writeback arbitration: per bank, lowest port first
  always_comb begin
    logic [3:0] taken;
    taken = '0;
    wb_ready = '0;
    for (int k = 0; k < NWB; k++) begin
      logic [1:0] b;
      b = bank(wb_warp[k], wb_rd[k]);
      if (wb_valid[k] && !taken[b]) begin
        wb_ready[k] = 1'b1;
        taken[b] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      occ <= 1'b0; need_a <= 1'b0; need_b <= 1'b0;
      for (int w = 0; w < NW; w++) for (int r = 0; r < NREG; r++) for (int l = 0; l < LANES; l++) rf[w][r][l] <= '0;
    end else begin
      // operand reads (values read before this cycle's writes)
      if (rd_a) begin
        for (int l = 0; l < LANES; l++) c_a[l] <= (ra == 0) ? 32'd0 : rf[c_warp][ra][l];
        need_a <= 1'b0;
      end
      if (rd_b) begin
        for (int l = 0; l < LANES; l++) c_b[l] <= (rb == 0) ? 32'd0 : rf[c_warp][rb][l];
        need_b <= 1'b0;
      end
      if (ex_fire) occ <= 1'b0;
      if (is_valid && is_ready) begin
        occ     <= 1'b1;
        c_warp  <= is_warp;
        c_instr <= is_instr;
        c_pc    <= is_pc;
        c_mask  <= is_mask;
        need_a  <= uses_a(is_instr);
        need_b  <= uses_b(is_instr);
        for (int l = 0; l < LANES; l++) begin c_a[l] <= '0; c_b[l] <= '0; end
      end
      // writes
      for (int k = 0; k < NWB; k++)
        if (wb_valid[k] && wb_ready[k] && wb_rd[k] != 0)
          for (int l = 0; l < LANES; l++)
`ifdef BUG_WRITE_ALL_LANES
            rf[wb_warp[k]][wb_rd[k]][l] <= wb_data[k][l];
`else
            if (wb_mask[k][l]) rf[wb_warp[k]][wb_rd[k]][l] <= wb_data[k][l];
`endif
      for (int w = 0; w < NW; w++)
        if (wl_mask[w]) for (int r = 0; r < NREG; r++) for (int l = 0; l < LANES; l++) rf[w][r][l] <= '0;
    end
  end
endmodule
