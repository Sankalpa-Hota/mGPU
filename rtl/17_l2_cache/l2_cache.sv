// One bank of the L2 cache (UCHE). Write-back, write-allocate, 2-way set associative, LRU, 32-byte lines.
// The bank only sees lines whose bank bits match; the set index is taken above the bank bits:
//   index = addr[5+BW +: IW], tag = the bits above.
// Requests (one at a time) carry an id that is returned with the answer.
//   read hit       : answer next cycle
//   read miss      : write back the LRU victim if dirty, fill the line, answer
//   write hit      : merge the strobed bytes, mark dirty, answer
//   write miss     : evict as above; a write that covers the whole line installs directly (no fill),
//                    a partial write fills the line first and merges into it; the line becomes dirty
// flush_req      : clean and invalidate: write back every dirty line, then mark every line invalid, then pulse
//                  flush_done. (The CPU writes DRAM directly between kernels, so no line may stay cached.)
// A memory answer with err set (address fault) is passed back as zeros and the line is not installed.
module l2_cache #(
  parameter int SETS = 32,
  parameter int NB   = 2,
  parameter int IDW  = 2,
  parameter int BANK = 0,      // which bank this instance is (its address bits [5 +: BW])
  localparam int IW = $clog2(SETS),
  localparam int BW = (NB > 1) ? $clog2(NB) : 0,
  localparam int TW = 32 - 5 - BW - IW
) (
  input  logic           clk,
  input  logic           rst_n,
  input  logic           req_valid,
  output logic           req_ready,
  input  logic [31:0]    req_addr,
  input  logic           req_we,
  input  logic [255:0]   req_wdata,
  input  logic [31:0]    req_wstrb,
  input  logic [IDW-1:0] req_id,
  output logic           rsp_valid,
  output logic [255:0]   rsp_data,
  output logic [IDW-1:0] rsp_id,
  input  logic           flush_req,
  output logic           flush_done,
  output logic           mreq_valid,
  input  logic           mreq_ready,
  output logic [31:0]    mreq_addr,
  output logic           mreq_we,
  output logic [255:0]   mreq_wdata,
  input  logic           mrsp_valid,
  input  logic [255:0]   mrsp_data,
  input  logic           mrsp_err,
  output logic           busy
);
  logic [255:0]  data  [SETS][2];
  logic [TW-1:0] tag   [SETS][2];
  logic          valid [SETS][2];
  logic          dirty [SETS][2];
  logic          lru   [SETS];

  typedef enum logic [3:0] {S_IDLE, S_LOOKUP, S_WB_REQ, S_WB_WAIT, S_FILL_REQ, S_FILL_WAIT, S_DONE,
                            S_FLUSH_SCAN, S_FLUSH_REQ, S_FLUSH_WAIT} state_t;
  state_t state;

  logic [31:0]    c_addr;
  logic           c_we;
  logic [255:0]   c_wdata;
  logic [31:0]    c_wstrb;
  logic [IDW-1:0] c_id;
  logic           c_way;
  logic [IW:0]    f_set;       // flush scan position: set * 2 + way
  logic [255:0]   fill;
  logic           fill_err;

  function automatic logic [IW-1:0] idx_of(logic [31:0] a); return a[5+BW +: IW]; endfunction
  function automatic logic [TW-1:0] tag_of(logic [31:0] a); return a[31 -: TW]; endfunction
  function automatic logic [255:0] merge(logic [255:0] o, logic [255:0] n, logic [31:0] s);
    for (int b = 0; b < 32; b++) if (s[b]) o[8*b +: 8] = n[8*b +: 8];
    return o;
  endfunction
  // rebuild a line address from tag and index; the bank bits are this bank's number
  function automatic logic [31:0] addr_of(logic [TW-1:0] t, logic [IW-1:0] i);
    logic [31:0] a;
    a = '0;
    a[31 -: TW] = t;
    a[5+BW +: IW] = i;
    a[5 +: BW] = BW'(BANK);
    return a;
  endfunction

  // after the victim is handled: a write covering the whole line needs no fill
  logic skip_fill;
`ifdef BUG_PARTIAL_NO_FILL
  assign skip_fill = c_we;
`else
  assign skip_fill = c_we && c_wstrb == '1;
`endif

  logic [IW-1:0] ci;
  assign ci = idx_of(c_addr);
  logic h0, h1;
  assign h0 = valid[ci][0] && tag[ci][0] == tag_of(c_addr);
  assign h1 = valid[ci][1] && tag[ci][1] == tag_of(c_addr);

  assign req_ready = (state == S_IDLE) && !flush_req;
  assign busy      = (state != S_IDLE);

  // flush scan entry
  logic [IW-1:0] fs;
  logic          fw;
  assign fs = f_set[IW:1];
  assign fw = f_set[0];

  always_comb begin
    mreq_valid = 1'b0; mreq_addr = '0; mreq_we = 1'b0; mreq_wdata = '0;
    case (state)
      S_WB_REQ:    begin mreq_valid = 1'b1; mreq_we = 1'b1; mreq_addr = addr_of(tag[ci][c_way], ci); mreq_wdata = data[ci][c_way]; end
      S_FILL_REQ:  begin mreq_valid = 1'b1; mreq_addr = {c_addr[31:5], 5'd0}; end
      S_FLUSH_REQ: begin mreq_valid = 1'b1; mreq_we = 1'b1; mreq_addr = addr_of(tag[fs][fw], fs); mreq_wdata = data[fs][fw]; end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE; rsp_valid <= 1'b0; flush_done <= 1'b0; f_set <= '0;
      for (int s = 0; s < SETS; s++) begin
        lru[s] <= 1'b0;
        for (int w = 0; w < 2; w++) begin valid[s][w] <= 1'b0; dirty[s][w] <= 1'b0; end
      end
    end else begin
      rsp_valid <= 1'b0;
      flush_done <= 1'b0;
      case (state)
        S_IDLE: begin
          if (flush_req) begin
            f_set <= '0;
            state <= S_FLUSH_SCAN;
          end else if (req_valid) begin
            c_addr <= req_addr; c_we <= req_we; c_wdata <= req_wdata; c_wstrb <= req_wstrb; c_id <= req_id;
            state <= S_LOOKUP;
          end
        end
        S_LOOKUP: begin
          if (h0 || h1) begin
            logic w;
            w = h1;
            lru[ci] <= !w;
            if (c_we) begin
              data[ci][w]  <= merge(data[ci][w], c_wdata, c_wstrb);
`ifndef BUG_DIRTY_NOT_SET
              dirty[ci][w] <= 1'b1;
`endif
              rsp_data <= '0;
            end else rsp_data <= data[ci][w];
            rsp_id <= c_id;
            rsp_valid <= 1'b1;
            state <= S_IDLE;
          end else begin
            c_way <= lru[ci];
            fill <= '0; fill_err <= 1'b0;
`ifdef BUG_NO_WRITEBACK
            state <= skip_fill ? S_DONE : S_FILL_REQ;
`else
            if (valid[ci][lru[ci]] && dirty[ci][lru[ci]]) state <= S_WB_REQ;
            else state <= skip_fill ? S_DONE : S_FILL_REQ;
`endif
          end
        end
        S_WB_REQ:  if (mreq_ready) state <= S_WB_WAIT;
        S_WB_WAIT: if (mrsp_valid) begin
          dirty[ci][c_way] <= 1'b0;
          state <= skip_fill ? S_DONE : S_FILL_REQ;
        end
        S_FILL_REQ: if (mreq_ready) state <= S_FILL_WAIT;
        S_FILL_WAIT: if (mrsp_valid) begin
          fill <= mrsp_err ? '0 : mrsp_data;
          fill_err <= mrsp_err;
          state <= S_DONE;
        end
        S_DONE: begin
          if (!fill_err) begin
            data[ci][c_way]  <= c_we ? merge(fill, c_wdata, c_wstrb) : fill;
            tag[ci][c_way]   <= tag_of(c_addr);
            valid[ci][c_way] <= 1'b1;
            dirty[ci][c_way] <= c_we;
            lru[ci]          <= !c_way;
          end
          rsp_data  <= c_we ? '0 : fill;
          rsp_id    <= c_id;
          rsp_valid <= 1'b1;
          state <= S_IDLE;
        end
        S_FLUSH_SCAN: begin
          if (valid[fs][fw] && dirty[fs][fw]) state <= S_FLUSH_REQ;
          else begin
`ifndef BUG_FLUSH_KEEPS_LINES
            valid[fs][fw] <= 1'b0;
`endif
            if (f_set == (IW+1)'(2 * SETS - 1)) begin flush_done <= 1'b1; state <= S_IDLE; end
            else f_set <= f_set + 1;
          end
        end
        S_FLUSH_REQ:  if (mreq_ready) state <= S_FLUSH_WAIT;
        S_FLUSH_WAIT: if (mrsp_valid) begin
          dirty[fs][fw] <= 1'b0;
`ifndef BUG_FLUSH_KEEPS_LINES
          valid[fs][fw] <= 1'b0;
`endif
          if (f_set == (IW+1)'(2 * SETS - 1)) begin flush_done <= 1'b1; state <= S_IDLE; end
          else begin f_set <= f_set + 1; state <= S_FLUSH_SCAN; end
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
