// L1 data cache of one SM: 2-way set associative, SETS sets x 32-byte lines, LRU replacement.
// addr[4:0] byte in line, addr[IW+4:5] set index, addr[31:IW+5] tag.
// Reads : hit -> line returned on the next cycle; miss -> fill the line from memory into the LRU way, answer.
// Writes: write-through, no write-allocate. The write (with byte strobes) always goes to memory; the answer is
//         given after memory acknowledges. If the line is cached, the strobed bytes are merged into it too.
// Any access that hits makes its way the most recently used.
// invalidate clears all lines (used at kernel boundaries: L1s of different SMs are not kept coherent);
// a fill in flight when invalidate arrives answers its requester but is not installed.
module l1_dcache #(
  parameter int SETS = 16,
  localparam int IW = $clog2(SETS),
  localparam int TW = 32 - IW - 5
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         req_valid,
  output logic         req_ready,
  input  logic [31:0]  req_addr,
  input  logic         req_we,
  input  logic [255:0] req_wdata,
  input  logic [31:0]  req_wstrb,
  output logic         rsp_valid,
  output logic [255:0] rsp_data,
  input  logic         invalidate,
  output logic         mreq_valid,
  input  logic         mreq_ready,
  output logic [31:0]  mreq_addr,
  output logic         mreq_we,
  output logic [255:0] mreq_wdata,
  output logic [31:0]  mreq_wstrb,
  input  logic         mrsp_valid,
  input  logic [255:0] mrsp_data,
  output logic         last_hit
);
  logic [255:0]  data  [SETS][2];
  logic [TW-1:0] tag   [SETS][2];
  logic          valid [SETS][2];
  logic          lru   [SETS];         // way to replace next

  typedef enum logic [1:0] {S_IDLE, S_REQ, S_WAIT} state_t;
  state_t state;
  logic [31:0]  c_addr;
  logic         c_we;
  logic [255:0] c_wdata;
  logic [31:0]  c_wstrb;
  logic         discard;

  logic [IW-1:0] idx;
  logic [TW-1:0] tg;
  logic h0, h1, hit;
  assign idx = req_addr[IW+4:5];
  assign tg  = req_addr[31:IW+5];
  assign h0  = valid[idx][0] && tag[idx][0] == tg;
  assign h1  = valid[idx][1] && tag[idx][1] == tg;
  assign hit = (h0 || h1) && !invalidate;

  assign req_ready  = (state == S_IDLE);
  assign mreq_valid = (state == S_REQ);
  assign mreq_addr  = {c_addr[31:5], 5'd0};
  assign mreq_we    = c_we;
  assign mreq_wdata = c_wdata;
  assign mreq_wstrb = c_wstrb;

  function automatic logic [255:0] merge(logic [255:0] old, logic [255:0] nw, logic [31:0] st);
    for (int b = 0; b < 32; b++) if (st[b]) old[8*b +: 8] = nw[8*b +: 8];
    return old;
  endfunction

  logic [IW-1:0] cidx;
  logic [TW-1:0] ctg;
  assign cidx = c_addr[IW+4:5];
  assign ctg  = c_addr[31:IW+5];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE; rsp_valid <= 1'b0; discard <= 1'b0; last_hit <= 1'b0;
      for (int s = 0; s < SETS; s++) begin valid[s][0] <= 1'b0; valid[s][1] <= 1'b0; lru[s] <= 1'b0; end
    end else begin
      rsp_valid <= 1'b0;
      case (state)
        S_IDLE: if (req_valid) begin
          c_addr <= req_addr; c_we <= req_we; c_wdata <= req_wdata; c_wstrb <= req_wstrb;
          discard <= 1'b0;
          last_hit <= hit;
          if (hit) begin
`ifdef BUG_LRU
            lru[idx] <= 1'b0;
`else
            lru[idx] <= h0 ? 1'b1 : 1'b0;
`endif
          end
          if (req_we) begin
`ifndef BUG_WRITE_NO_UPDATE
            if (hit) begin
`ifdef BUG_STRB_MERGE
              if (h0) data[idx][0] <= req_wdata; else data[idx][1] <= req_wdata;
`else
              if (h0) data[idx][0] <= merge(data[idx][0], req_wdata, req_wstrb);
              else    data[idx][1] <= merge(data[idx][1], req_wdata, req_wstrb);
`endif
            end
`endif
            state <= S_REQ;
          end else if (hit) begin
            rsp_valid <= 1'b1;
            rsp_data  <= h0 ? data[idx][0] : data[idx][1];
          end else state <= S_REQ;
        end
        S_REQ:  if (mreq_ready) state <= S_WAIT;
        S_WAIT: if (mrsp_valid) begin
          rsp_valid <= 1'b1;
          rsp_data  <= mrsp_data;
          if (!c_we && !discard && !invalidate) begin
            data[cidx][lru[cidx]]  <= mrsp_data;
            tag[cidx][lru[cidx]]   <= ctg;
            valid[cidx][lru[cidx]] <= 1'b1;
`ifdef BUG_LRU
            lru[cidx] <= 1'b0;
`else
            lru[cidx] <= ~lru[cidx];
`endif
          end
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
      if (invalidate) begin
        for (int s = 0; s < SETS; s++) begin valid[s][0] <= 1'b0; valid[s][1] <= 1'b0; end
        if (state != S_IDLE) discard <= 1'b1;
      end
    end
  end
endmodule
