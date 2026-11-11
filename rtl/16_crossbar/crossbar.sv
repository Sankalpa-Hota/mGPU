// Crossbar: N requesters (each with at most one request outstanding) to NB L2 banks.
// Bank = line address bits [5 + log2(NB) - 1 : 5], so consecutive lines alternate between banks.
// Per bank: round-robin among the requesters that target it; a request offered to a bank stays selected until
// the bank accepts it. The request carries the requester id; the bank answers with that id (banks may have
// several requests in flight and answer in any order) and the crossbar returns the answer to that requester.
module crossbar #(
  parameter int N  = 4,
  parameter int NB = 2,
  localparam int IW = $clog2(N),
  localparam int BW = (NB > 1) ? $clog2(NB) : 1
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic [N-1:0]  req_valid,
  output logic [N-1:0]  req_ready,
  input  logic [31:0]   req_addr  [N],
  input  logic          req_we    [N],
  input  logic [255:0]  req_wdata [N],
  input  logic [31:0]   req_wstrb [N],
  output logic [N-1:0]  rsp_valid,
  output logic [255:0]  rsp_data  [N],
  output logic [NB-1:0] b_valid,
  input  logic [NB-1:0] b_ready,
  output logic [31:0]   b_addr  [NB],
  output logic          b_we    [NB],
  output logic [255:0]  b_wdata [NB],
  output logic [31:0]   b_wstrb [NB],
  output logic [IW-1:0] b_id    [NB],
  input  logic [NB-1:0] b_rsp_valid,
  input  logic [255:0]  b_rsp_data [NB],
  input  logic [IW-1:0] b_rsp_id   [NB]
);
  function automatic logic [BW-1:0] bank_of(logic [31:0] a);
`ifdef BUG_BANK_BIT
    return BW'(a >> 6);
`else
    return BW'(a >> 5);
`endif
  endfunction

  logic [IW-1:0] rr   [NB];
  logic [IW-1:0] sel  [NB];
  logic [IW-1:0] held_id [NB];
  logic [NB-1:0] held;

  always_comb begin
    req_ready = '0;
    for (int b = 0; b < NB; b++) begin
      logic          any;
      logic [IW-1:0] pick;
      any = 1'b0;
      pick = '0;
      for (int k = N - 1; k >= 0; k--) begin
        logic [IW-1:0] r;
        r = IW'((rr[b] + k) % N);
        if (req_valid[r] && bank_of(req_addr[r]) == b) begin any = 1'b1; pick = r; end
      end
`ifdef BUG_NO_HOLD
      sel[b] = pick;
      b_valid[b] = any;
`else
      sel[b] = held[b] ? held_id[b] : pick;
      b_valid[b] = held[b] || any;
`endif
      b_addr[b]  = req_addr[sel[b]];
      b_we[b]    = req_we[sel[b]];
      b_wdata[b] = req_wdata[sel[b]];
      b_wstrb[b] = req_wstrb[sel[b]];
      b_id[b]    = sel[b];
      if (b_valid[b] && b_ready[b]) req_ready[sel[b]] = 1'b1;
    end
  end

  // responses: each bank answer goes to the requester named by its id
  logic [IW-1:0] last_grant [NB];
  always_comb begin
    rsp_valid = '0;
    for (int r = 0; r < N; r++) rsp_data[r] = '0;
    for (int b = 0; b < NB; b++)
      if (b_rsp_valid[b]) begin
`ifdef BUG_RSP_ROUTE
        rsp_valid[last_grant[b]] = 1'b1;
        rsp_data[last_grant[b]]  = b_rsp_data[b];
`else
        rsp_valid[b_rsp_id[b]] = 1'b1;
        rsp_data[b_rsp_id[b]]  = b_rsp_data[b];
`endif
      end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      held <= '0;
      for (int b = 0; b < NB; b++) begin rr[b] <= '0; held_id[b] <= '0; last_grant[b] <= '0; end
    end else
      for (int b = 0; b < NB; b++) begin
        held[b]    <= b_valid[b] && !b_ready[b];
        held_id[b] <= sel[b];
        if (b_valid[b] && b_ready[b]) begin
          rr[b] <= IW'((sel[b] + 1) % N);
          last_grant[b] <= sel[b];
        end
      end
  end
endmodule
