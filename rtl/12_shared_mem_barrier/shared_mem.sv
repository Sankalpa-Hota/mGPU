// Shared memory of one sub-core: WORDS x 32 bits in 8 banks, word w in bank w % 8, row w / 8.
// Addresses are byte addresses; bits [1:0] are ignored and the address wraps modulo the memory size.
// A warp access (LDS / STS, up to 8 active lanes) is served in passes. In each pass, every bank serves one
// word: the word of the lowest pending lane that maps to that bank. All pending lanes asking for that same
// word are served in the same pass (reads: broadcast; writes: the highest such lane wins).
// So an access takes as many passes as the largest number of DIFFERENT words requested from one bank.
module shared_mem
  import mgpu_pkg::*;
#(
  parameter int WORDS = 128,
  parameter int NW = 4,
  localparam int WW = $clog2(NW),
  localparam int AW = $clog2(WORDS)
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             req_valid,
  output logic             req_ready,
  input  logic             req_we,
  input  logic [LANES-1:0] req_mask,
  input  logic [31:0]      req_addr  [LANES],
  input  logic [31:0]      req_wdata [LANES],
  input  logic [WW-1:0]    req_warp,
  input  logic [3:0]       req_rd,
  output logic             rsp_valid,
  output logic             rsp_we,
  output logic [WW-1:0]    rsp_warp,
  output logic [3:0]       rsp_rd,
  output logic [LANES-1:0] rsp_mask,
  output logic [31:0]      rsp_data [LANES],
  output logic [3:0]       last_passes
);
  logic [31:0] mem [WORDS];

  logic             busy;
  logic [LANES-1:0] pend;
  logic             c_we;
  logic [AW-1:0]    c_word [LANES];
  logic [31:0]      c_wdata [LANES];
  logic [3:0]       passes;

  assign req_ready = !busy;

  // choose this pass: per bank, the word of the lowest pending lane in that bank
  logic [LANES-1:0] serve;
  always_comb begin
    logic [7:0]    bank_used;
    logic [AW-1:0] bank_word [8];
    bank_used = '0;
    serve = '0;
    for (int b = 0; b < 8; b++) bank_word[b] = '0;
    for (int l = 0; l < LANES; l++)
      if (pend[l]) begin
        logic [2:0] b;
        b = c_word[l][2:0];
`ifdef BUG_NO_BROADCAST
        if (!bank_used[b]) begin bank_used[b] = 1'b1; bank_word[b] = c_word[l]; serve[l] = 1'b1; end
`else
        if (!bank_used[b]) begin bank_used[b] = 1'b1; bank_word[b] = c_word[l]; serve[l] = 1'b1; end
        else if (bank_word[b] == c_word[l]) serve[l] = 1'b1;
`endif
      end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; pend <= '0; rsp_valid <= 1'b0; passes <= '0; last_passes <= '0;
    end else begin
      rsp_valid <= 1'b0;
      if (req_valid && req_ready) begin
        busy    <= 1'b1;
        pend    <= req_mask;
        c_we    <= req_we;
        passes  <= '0;
        rsp_we  <= req_we; rsp_warp <= req_warp; rsp_rd <= req_rd; rsp_mask <= req_mask;
        for (int l = 0; l < LANES; l++) begin
          c_word[l]  <= req_addr[l][AW+1:2];
          c_wdata[l] <= req_wdata[l];
          rsp_data[l] <= '0;
        end
      end else if (busy) begin
        if (pend == '0) begin
          busy <= 1'b0;
          rsp_valid <= 1'b1;
          last_passes <= passes;
        end else begin
          passes <= passes + 1;
`ifdef BUG_NO_CONFLICT
          pend <= '0;
          for (int l = 0; l < LANES; l++)
            if (pend[l]) begin
              if (c_we) mem[c_word[l]] <= c_wdata[l];
              else rsp_data[l] <= mem[c_word[l]];
            end
`else
          pend <= pend & ~serve;
`ifdef BUG_WRITE_ORDER
          for (int l = LANES - 1; l >= 0; l--)     // descending: the LOWEST lane's write lands last (wrong)
`else
          for (int l = 0; l < LANES; l++)          // ascending: the highest lane's write lands last
`endif
            if (serve[l]) begin
              if (c_we) mem[c_word[l]] <= c_wdata[l];
              else rsp_data[l] <= mem[c_word[l]];
            end
`endif
        end
      end
    end
  end
endmodule
