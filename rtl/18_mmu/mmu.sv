// MMU: translates the virtual line addresses coming out of the L2 into physical addresses for GBIF.
// Two-level page table, 4 KB pages:
//   VA[31:22] index into the level-1 table at PTBR, VA[21:12] index into the level-2 table, VA[11:0] offset.
//   PTE: [31:12] physical page number, [1] W (writable), [0] V (valid).
//   A level-1 PTE points to a level-2 table; a level-2 PTE maps the page.
// TLB: TLB_N entries, fully associative, round-robin replacement; invalidate clears it.
// Page walk reads go out through the same downstream port. One request at a time.
// Fault (level-1 or level-2 PTE not valid, or a write to a page without W): the request is answered with
// err = 1 and zero data and never reaches memory; fault_valid (sticky until fault_clear) and fault_va/fault_write
// record the first fault for software.
// enable = 0: no translation, PA = VA.
module mmu #(
  parameter int TLB_N = 8,
  localparam int TW = $clog2(TLB_N)
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         enable,
  input  logic [31:0]  ptbr,
  input  logic         tlb_invalidate,
  input  logic         req_valid,
  output logic         req_ready,
  input  logic [31:0]  req_addr,
  input  logic         req_we,
  input  logic [255:0] req_wdata,
  input  logic [31:0]  req_wstrb,
  output logic         rsp_valid,
  output logic [255:0] rsp_data,
  output logic         rsp_err,
  output logic         mreq_valid,
  input  logic         mreq_ready,
  output logic [31:0]  mreq_addr,
  output logic         mreq_we,
  output logic [255:0] mreq_wdata,
  output logic [31:0]  mreq_wstrb,
  input  logic         mrsp_valid,
  input  logic [255:0] mrsp_data,
  output logic         fault_valid,
  output logic [31:0]  fault_va,
  output logic         fault_write,
  input  logic         fault_clear,
  output logic         stat_tlb_hit,
  output logic         stat_walk
);
  logic          t_valid [TLB_N];
  logic [19:0]   t_vpn   [TLB_N];
  logic [19:0]   t_ppn   [TLB_N];
  logic          t_w     [TLB_N];
  logic [TW-1:0] t_rr;

  typedef enum logic [2:0] {S_IDLE, S_LOOK, S_PTE1_REQ, S_PTE1_WAIT, S_PTE2_REQ, S_PTE2_WAIT, S_ACC_REQ, S_ACC_WAIT} state_t;
  state_t state;
  logic [31:0]  c_va;
  logic         c_we;
  logic [255:0] c_wdata;
  logic [31:0]  c_wstrb;
  logic [19:0]  c_ppn;
  logic [31:0]  pte1;

  // TLB lookup on the current request
  logic          hit, hit_w;
  logic [19:0]   hit_ppn;
  always_comb begin
    hit = 1'b0; hit_w = 1'b0; hit_ppn = '0;
    for (int i = 0; i < TLB_N; i++)
      if (t_valid[i] && t_vpn[i] == c_va[31:12]) begin hit = 1'b1; hit_w = t_w[i]; hit_ppn = t_ppn[i]; end
  end

  logic [31:0] pte1_addr, pte2_addr;
  assign pte1_addr = {ptbr[31:12], 12'd0} + {20'd0, c_va[31:22], 2'b00};
`ifdef BUG_PTE_INDEX
  assign pte2_addr = {pte1[31:12], 12'd0} + {20'd0, c_va[20:11], 2'b00};
`else
  assign pte2_addr = {pte1[31:12], 12'd0} + {20'd0, c_va[21:12], 2'b00};
`endif

  assign req_ready = (state == S_IDLE);
  always_comb begin
    mreq_valid = 1'b0; mreq_addr = '0; mreq_we = 1'b0; mreq_wdata = '0; mreq_wstrb = '0;
    case (state)
      S_PTE1_REQ: begin mreq_valid = 1'b1; mreq_addr = {pte1_addr[31:5], 5'd0}; end
      S_PTE2_REQ: begin mreq_valid = 1'b1; mreq_addr = {pte2_addr[31:5], 5'd0}; end
      S_ACC_REQ:  begin mreq_valid = 1'b1; mreq_addr = {c_ppn, c_va[11:5], 5'd0}; mreq_we = c_we;
                        mreq_wdata = c_wdata; mreq_wstrb = c_wstrb; end
      default: ;
    endcase
  end

  logic [31:0] pte_word;
  assign pte_word = mrsp_data[32 * ((state == S_PTE1_WAIT) ? pte1_addr[4:2] : pte2_addr[4:2]) +: 32];

  task automatic fault();
    rsp_valid <= 1'b1;
    rsp_err   <= 1'b1;
    rsp_data  <= '0;
    if (!fault_valid) begin fault_valid <= 1'b1; fault_va <= c_va; fault_write <= c_we; end
    state <= S_IDLE;
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE; rsp_valid <= 1'b0; rsp_err <= 1'b0; fault_valid <= 1'b0; fault_va <= '0; fault_write <= 1'b0;
      t_rr <= '0; stat_tlb_hit <= 1'b0; stat_walk <= 1'b0;
      for (int i = 0; i < TLB_N; i++) t_valid[i] <= 1'b0;
    end else begin
      rsp_valid <= 1'b0; rsp_err <= 1'b0; stat_tlb_hit <= 1'b0; stat_walk <= 1'b0;
      if (fault_clear) fault_valid <= 1'b0;
      case (state)
        S_IDLE: if (req_valid) begin
          c_va <= req_addr; c_we <= req_we; c_wdata <= req_wdata; c_wstrb <= req_wstrb;
          state <= S_LOOK;
        end
        S_LOOK: begin
          if (!enable) begin c_ppn <= c_va[31:12]; state <= S_ACC_REQ; end
          else if (hit) begin
            stat_tlb_hit <= 1'b1;
`ifdef BUG_PERM
            begin c_ppn <= hit_ppn; state <= S_ACC_REQ; end
`else
            if (c_we && !hit_w) fault();
            else begin c_ppn <= hit_ppn; state <= S_ACC_REQ; end
`endif
          end else begin stat_walk <= 1'b1; state <= S_PTE1_REQ; end
        end
        S_PTE1_REQ:  if (mreq_ready) state <= S_PTE1_WAIT;
        S_PTE1_WAIT: if (mrsp_valid) begin
          pte1 <= pte_word;
          if (!pte_word[0]) fault();
          else state <= S_PTE2_REQ;
        end
        S_PTE2_REQ:  if (mreq_ready) state <= S_PTE2_WAIT;
        S_PTE2_WAIT: if (mrsp_valid) begin
          if (!pte_word[0]) fault();
          else begin
            // install in the TLB (also when the access itself then faults on permission)
            t_valid[t_rr] <= 1'b1; t_vpn[t_rr] <= c_va[31:12]; t_ppn[t_rr] <= pte_word[31:12]; t_w[t_rr] <= pte_word[1];
            t_rr <= TW'(t_rr + 1);
`ifdef BUG_PERM
            begin c_ppn <= pte_word[31:12]; state <= S_ACC_REQ; end
`else
            if (c_we && !pte_word[1]) fault();
            else begin c_ppn <= pte_word[31:12]; state <= S_ACC_REQ; end
`endif
          end
        end
        S_ACC_REQ:  if (mreq_ready) state <= S_ACC_WAIT;
        S_ACC_WAIT: if (mrsp_valid) begin
          rsp_valid <= 1'b1;
          rsp_data  <= mrsp_data;
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
`ifndef BUG_TLB_NO_INVAL
      if (tlb_invalidate) for (int i = 0; i < TLB_N; i++) t_valid[i] <= 1'b0;
`endif
    end
  end
endmodule
