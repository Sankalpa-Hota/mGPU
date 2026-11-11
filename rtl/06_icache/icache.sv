// Instruction cache: direct mapped, LINES x 32-byte lines (8 instructions), shared by NPORT requesters.
// pc[4:2] = word in line, pc[IW+4:5] = index, pc[31:IW+5] = tag.
// One request is accepted per cycle (round-robin between ports). A hit answers on the next cycle.
// A miss blocks the cache: one line fill from memory, then the answer. invalidate clears every line; a fill
// that was in flight when invalidate arrived still answers its requester but is not installed.
module icache #(
  parameter int NPORT = 2,
  parameter int LINES = 16,
  localparam int IW = $clog2(LINES),
  localparam int PW = (NPORT > 1) ? $clog2(NPORT) : 1
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic [NPORT-1:0]   req_valid,
  output logic [NPORT-1:0]   req_ready,
  input  logic [31:0]        req_pc [NPORT],
  output logic [NPORT-1:0]   rsp_valid,
  output logic [31:0]        rsp_instr,
  input  logic               invalidate,
  output logic               mreq_valid,
  input  logic               mreq_ready,
  output logic [31:0]        mreq_addr,
  input  logic               mrsp_valid,
  input  logic [255:0]       mrsp_data
);
  localparam int TW = 32 - IW - 5;

  logic [255:0]  data  [LINES];
  logic [TW-1:0] tag   [LINES];
  logic [LINES-1:0] valid;

  typedef enum logic [1:0] {S_IDLE, S_REQ, S_WAIT} state_t;
  state_t state;
  logic [PW-1:0] rr, grant, miss_port;
  logic          any;
  logic [31:0]   miss_pc;
  logic          discard;

  // round-robin grant
  always_comb begin
    any = 1'b0;
    grant = '0;
`ifdef BUG_FIXED_PRIO
    for (int k = NPORT - 1; k >= 0; k--)
      if (req_valid[k]) begin any = 1'b1; grant = PW'(k); end
`else
    for (int k = NPORT - 1; k >= 0; k--) begin
      logic [PW-1:0] p;
      p = PW'((rr + k) % NPORT);
      if (req_valid[p]) begin any = 1'b1; grant = p; end
    end
`endif
  end

  logic [31:0]   gpc;
  logic [IW-1:0] gidx;
  logic [TW-1:0] gtag;
  logic          ghit;
  assign gpc  = req_pc[grant];
  assign gidx = gpc[IW+4:5];
  assign gtag = gpc[31:IW+5];
`ifdef BUG_NO_VALID
  assign ghit = (tag[gidx] == gtag);
`elsif BUG_TAG_BITS
  assign ghit = valid[gidx] && (tag[gidx][TW-2:0] == gtag[TW-2:0]);
`else
  assign ghit = valid[gidx] && (tag[gidx] == gtag);
`endif

  logic take;
  assign take = (state == S_IDLE) && any;
  always_comb begin
    req_ready = '0;
    if (state == S_IDLE && any) req_ready[grant] = 1'b1;
  end

  assign mreq_valid = (state == S_REQ);
  assign mreq_addr  = {miss_pc[31:5], 5'd0};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE; rr <= '0; valid <= '0; rsp_valid <= '0; rsp_instr <= '0;
      miss_port <= '0; miss_pc <= '0; discard <= 1'b0;
    end else begin
      rsp_valid <= '0;
      case (state)
        S_IDLE: if (take) begin
          rr <= PW'((grant + 1) % NPORT);
          if (ghit && !invalidate) begin
            rsp_valid[grant] <= 1'b1;
            rsp_instr <= data[gidx][32*gpc[4:2] +: 32];
          end else begin
            miss_port <= grant;
            miss_pc   <= gpc;
            discard   <= 1'b0;
            state     <= S_REQ;
          end
        end
        S_REQ:  if (mreq_ready) state <= S_WAIT;
        S_WAIT: if (mrsp_valid) begin
          if (!discard && !invalidate) begin
            data[miss_pc[IW+4:5]]  <= mrsp_data;
            tag[miss_pc[IW+4:5]]   <= miss_pc[31:IW+5];
            valid[miss_pc[IW+4:5]] <= 1'b1;
          end
          rsp_valid[miss_port] <= 1'b1;
          rsp_instr <= mrsp_data[32*miss_pc[4:2] +: 32];
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
      if (invalidate) begin
        valid <= '0;
        if (state != S_IDLE) discard <= 1'b1;
      end
    end
  end
endmodule
