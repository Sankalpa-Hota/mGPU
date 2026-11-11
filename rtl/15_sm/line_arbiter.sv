// N requesters of the line port -> one line port. Round-robin; one request outstanding at a time;
// the response goes back to the requester that owns the outstanding request.
module line_arbiter #(
  parameter int N = 2,
  localparam int NW = (N > 1) ? $clog2(N) : 1
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic [N-1:0] in_valid,
  output logic [N-1:0] in_ready,
  input  logic [31:0]  in_addr  [N],
  input  logic         in_we    [N],
  input  logic [255:0] in_wdata [N],
  input  logic [31:0]  in_wstrb [N],
  output logic [N-1:0] in_rsp_valid,
  output logic [255:0] in_rsp_data,
  output logic         out_valid,
  input  logic         out_ready,
  output logic [31:0]  out_addr,
  output logic         out_we,
  output logic [255:0] out_wdata,
  output logic [31:0]  out_wstrb,
  input  logic         out_rsp_valid,
  input  logic [255:0] out_rsp_data
);
  logic          busy, held;
  logic [NW-1:0] owner, rr, pick, sel;
  logic          any;
  always_comb begin
    any = 1'b0;
    pick = '0;
    for (int k = N - 1; k >= 0; k--) begin
      logic [NW-1:0] p;
      p = NW'((rr + k) % N);
      if (in_valid[p]) begin any = 1'b1; pick = p; end
    end
  end
  // once a request is offered downstream it stays selected until accepted
  assign sel       = held ? owner : pick;
  assign out_valid = !busy && (held || any);
  assign out_addr  = in_addr[sel];
  assign out_we    = in_we[sel];
  assign out_wdata = in_wdata[sel];
  assign out_wstrb = in_wstrb[sel];
  always_comb begin
    in_ready = '0;
    if (out_valid && out_ready) in_ready[sel] = 1'b1;
    in_rsp_valid = '0;
    if (busy && out_rsp_valid) in_rsp_valid[owner] = 1'b1;
  end
  assign in_rsp_data = out_rsp_data;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; held <= 1'b0; owner <= '0; rr <= '0;
    end else begin
      if (out_valid && !out_ready) begin held <= 1'b1; owner <= sel; end
      if (out_valid && out_ready) begin
        busy <= 1'b1; held <= 1'b0; owner <= sel; rr <= NW'((sel + 1) % N);
      end
      if (busy && out_rsp_valid) busy <= 1'b0;
    end
  end
endmodule
