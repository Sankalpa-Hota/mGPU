// Load/store unit of one sub-core. One memory instruction at a time (keeps program order simple).
//   address of lane l = a[l] + imm  (bits [1:0] ignored: word accesses)
//   LDS / STS : one access to the shared memory (it handles bank conflicts itself)
//   LD  / ST  : coalesced. Repeatedly take the lowest active lane not yet served; every active lane whose
//               address is in the same 32-byte line is served by the same line request.
//               Loads pick each lane's word out of the returned line.
//               Stores build the line data and byte strobes; if two lanes store to the same word,
//               the higher lane wins. The memory answers a store with an acknowledge.
// Loads always end with a writeback (even with no active lane) so the scoreboard's pending bit is cleared.
module lsu
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
  // shared memory
  output logic             sm_valid,
  input  logic             sm_ready,
  output logic             sm_we,
  output logic [LANES-1:0] sm_mask,
  output logic [31:0]      sm_addr  [LANES],
  output logic [31:0]      sm_wdata [LANES],
  input  logic             sm_rsp_valid,
  input  logic [31:0]      sm_rsp_data [LANES],
  // L1 data cache (line port)
  output logic             mreq_valid,
  input  logic             mreq_ready,
  output logic [31:0]      mreq_addr,
  output logic             mreq_we,
  output logic [255:0]     mreq_wdata,
  output logic [31:0]      mreq_wstrb,
  input  logic             mrsp_valid,
  input  logic [255:0]     mrsp_data,
  // writeback
  output logic             wb_valid,
  input  logic             wb_ready,
  output logic [WW-1:0]    wb_warp,
  output logic [3:0]       wb_rd,
  output logic [LANES-1:0] wb_mask,
  output logic [31:0]      wb_data [LANES],
  output logic             busy,
  output logic [3:0]       last_lines
);
  typedef enum logic [2:0] {S_IDLE, S_SM_REQ, S_SM_WAIT, S_PICK, S_REQ, S_WAIT, S_WB} state_t;
  state_t state;

  logic [5:0]       op;
  logic [LANES-1:0] mask, pend, serve;
  logic [31:0]      addr  [LANES];
  logic [31:0]      sdata [LANES];
  logic [26:0]      line;
  logic [3:0]       lines;

  assign ex_ready = (state == S_IDLE);
  assign busy     = (state != S_IDLE);

  // lanes served by the line of the lowest pending lane
  logic [26:0] cur_line;
  always_comb begin
    cur_line = '0;
    for (int l = LANES - 1; l >= 0; l--) if (pend[l]) cur_line = addr[l][31:5];
    serve = '0;
    for (int l = 0; l < LANES; l++)
`ifdef BUG_COALESCE_OFF
      if (pend[l] && addr[l][31:5] == cur_line && (serve == '0)) serve[l] = 1'b1;
`else
      if (pend[l] && addr[l][31:5] == cur_line) serve[l] = 1'b1;
`endif
  end

  // shared memory request
  assign sm_valid = (state == S_SM_REQ);
  assign sm_we    = (op == OP_STS);
  assign sm_mask  = mask;
  assign sm_addr  = addr;
  assign sm_wdata = sdata;

  // line request
  logic [LANES-1:0] req_lanes;
  assign mreq_valid = (state == S_REQ);
  assign mreq_addr  = {line, 5'd0};
  assign mreq_we    = (op == OP_ST);
  always_comb begin
    mreq_wdata = '0;
    mreq_wstrb = '0;
    for (int l = 0; l < LANES; l++)
      if (req_lanes[l]) begin
`ifdef BUG_STRB_LANE
        mreq_wdata[32*l +: 32] = sdata[l];
        mreq_wstrb[4*l +: 4]   = 4'hF;
`else
        mreq_wdata[32*addr[l][4:2] +: 32] = sdata[l];
        mreq_wstrb[4*addr[l][4:2] +: 4]   = 4'hF;
`endif
      end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE; wb_valid <= 1'b0; last_lines <= '0; lines <= '0; pend <= '0; req_lanes <= '0;
    end else begin
      case (state)
        S_IDLE: if (ex_valid) begin
          op      <= f_op(ex_instr);
          mask    <= ex_mask;
          pend    <= ex_mask;
          wb_warp <= ex_warp;
          wb_rd   <= f_rd(ex_instr);
          wb_mask <= ex_mask;
          lines   <= '0;
          for (int l = 0; l < LANES; l++) begin
            addr[l]    <= ex_a[l] + f_imm(ex_instr);
            sdata[l]   <= ex_b[l];
            wb_data[l] <= '0;
          end
          state <= (f_op(ex_instr) == OP_LDS || f_op(ex_instr) == OP_STS) ? S_SM_REQ : S_PICK;
        end
        S_SM_REQ:  if (sm_ready) state <= S_SM_WAIT;
        S_SM_WAIT: if (sm_rsp_valid) begin
          if (op == OP_LDS) for (int l = 0; l < LANES; l++) wb_data[l] <= sm_rsp_data[l];
          state <= (op == OP_LDS) ? S_WB : S_IDLE;
          if (op == OP_LDS) wb_valid <= 1'b1;
        end
        S_PICK: begin
          if (pend == '0) begin
            last_lines <= lines;
            if (op == OP_LD) begin wb_valid <= 1'b1; state <= S_WB; end
            else state <= S_IDLE;
          end else begin
            line      <= cur_line;
            req_lanes <= serve;
            pend      <= pend & ~serve;
            lines     <= lines + 1;
            state     <= S_REQ;
          end
        end
        S_REQ:  if (mreq_ready) state <= S_WAIT;
        S_WAIT: if (mrsp_valid) begin
          if (op == OP_LD)
            for (int l = 0; l < LANES; l++)
              if (req_lanes[l])
`ifdef BUG_LOAD_WORD
                wb_data[l] <= mrsp_data[32*l +: 32];
`else
                wb_data[l] <= mrsp_data[32*addr[l][4:2] +: 32];
`endif
          state <= S_PICK;
        end
        S_WB: if (wb_ready) begin
          wb_valid <= 1'b0;
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
