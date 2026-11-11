// DRAM controller: an AXI4 slave (32-bit data, single ID) in front of the memory array.
//   - INCR bursts of 1..16 beats, size 4 bytes, with byte strobes on writes
//   - FIXED or WRAP bursts, or a size other than 4 bytes: answered with SLVERR, memory untouched
//   - an address at or beyond the memory size: DECERR (never wraps onto real memory)
//   - timing model: 4 banks (address bits [11:10]) each with one open row (bits [MW-1:12]); a burst that hits
//     the open row starts after T_HIT cycles, otherwise after T_MISS cycles (precharge + activate)
//   - one read and one write may be pending; when both are ready to start, they alternate
//   - each read beat is captured in a register when it is offered, so RDATA cannot change while RREADY is low
module dram_ctrl #(
  parameter int MW     = 20,    // memory size 2^MW bytes
  parameter int T_HIT  = 2,
  parameter int T_MISS = 8
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic [31:0]  araddr,
  input  logic [7:0]   arlen,
  input  logic [2:0]   arsize,
  input  logic [1:0]   arburst,
  input  logic         arvalid,
  output logic         arready,
  output logic [31:0]  rdata,
  output logic [1:0]   rresp,
  output logic         rlast,
  output logic         rvalid,
  input  logic         rready,
  input  logic [31:0]  awaddr,
  input  logic [7:0]   awlen,
  input  logic [2:0]   awsize,
  input  logic [1:0]   awburst,
  input  logic         awvalid,
  output logic         awready,
  input  logic [31:0]  wdata,
  input  logic [3:0]   wstrb,
  input  logic         wlast,
  input  logic         wvalid,
  output logic         wready,
  output logic [1:0]   bresp,
  output logic         bvalid,
  input  logic         bready,
  output logic         stat_row_hit,
  output logic         stat_row_miss
);
  logic [31:0] mem [2**(MW-2)];
  initial for (int i = 0; i < 2**(MW-2); i++) mem[i] = '0;   // simulation: memory starts as zeros
  logic [MW-13:0] open_row [4];
  logic           row_ok   [4];

  // ---------------- read side
  typedef enum logic [1:0] {R_IDLE, R_WAIT, R_DATA} rstate_t;
  rstate_t rs;
  logic [31:0] r_addr;
  logic [7:0]  r_left;
  logic [1:0]  r_resp;
  logic [3:0]  r_wait;
  // ---------------- write side
  typedef enum logic [2:0] {W_IDLE, W_WAIT, W_DATA, W_RESP} wstate_t;
  wstate_t ws;
  logic [31:0] w_addr;
  logic [1:0]  w_resp;
  logic [3:0]  w_wait;
  logic        last_was_read;

  function automatic logic [1:0] check(logic [31:0] a, logic [7:0] len, logic [2:0] size, logic [1:0] burst);
    if (burst != 2'b01 || size != 3'd2 || len > 8'd15) return 2'b10;        // SLVERR: unsupported
`ifdef BUG_NO_DECERR
    return 2'b00;
`else
    if ((a + ((len + 1) << 2)) > (32'd1 << MW) || a >= (32'd1 << MW)) return 2'b11;   // DECERR
    return 2'b00;
`endif
  endfunction

  function automatic logic [3:0] latency(logic [31:0] a);
    return (row_ok[a[11:10]] && open_row[a[11:10]] == a[MW-1:12]) ? 4'(T_HIT) : 4'(T_MISS);
  endfunction

  // start arbitration: when both could start, alternate
  logic r_go, w_go;
  assign r_go = (rs == R_IDLE) && arvalid && !(ws == W_IDLE && awvalid && last_was_read);
  assign w_go = (ws == W_IDLE) && awvalid && !r_go;
  assign arready = r_go;
  assign awready = w_go;

  assign rvalid = (rs == R_DATA);
`ifdef BUG_RDATA_LIVE
  assign rdata  = (r_resp == 2'b00) ? mem[r_addr[MW-1:2]] : 32'd0;    // live from the array: can change while stalled
`else
  logic [31:0] rdata_q;                                                // the offered beat is held until RREADY
  assign rdata  = rdata_q;
`endif
  assign rresp  = r_resp;
`ifdef BUG_RLAST_EARLY
  assign rlast  = (r_left == 8'd1) || (r_left == 8'd0);
`else
  assign rlast  = (r_left == 8'd0);
`endif
  assign wready = (ws == W_DATA);
  assign bvalid = (ws == W_RESP);
  assign bresp  = w_resp;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rs <= R_IDLE; ws <= W_IDLE; last_was_read <= 1'b0; stat_row_hit <= 1'b0; stat_row_miss <= 1'b0;
      for (int b = 0; b < 4; b++) row_ok[b] <= 1'b0;
    end else begin
      stat_row_hit <= 1'b0; stat_row_miss <= 1'b0;
      // read
      case (rs)
        R_IDLE: if (r_go) begin
          r_addr <= araddr; r_left <= arlen; r_resp <= check(araddr, arlen, arsize, arburst);
          r_wait <= latency(araddr);
          if (check(araddr, arlen, arsize, arburst) == 2'b00) begin
            if (latency(araddr) == 4'(T_HIT)) stat_row_hit <= 1'b1; else stat_row_miss <= 1'b1;
            open_row[araddr[11:10]] <= araddr[MW-1:12]; row_ok[araddr[11:10]] <= 1'b1;
          end
          last_was_read <= 1'b1;
          rs <= R_WAIT;
        end
        R_WAIT: if (r_wait <= 1) begin
          rs <= R_DATA;
`ifndef BUG_RDATA_LIVE
          rdata_q <= (r_resp == 2'b00) ? mem[r_addr[MW-1:2]] : 32'd0;
`endif
        end else r_wait <= r_wait - 1;
        R_DATA: if (rready) begin
          if (r_left == 0) rs <= R_IDLE;
          else begin
            r_left <= r_left - 1; r_addr <= r_addr + 4;
`ifndef BUG_RDATA_LIVE
            rdata_q <= (r_resp == 2'b00) ? mem[r_addr[MW-1:2] + 1] : 32'd0;
`endif
          end
        end
        default: rs <= R_IDLE;
      endcase
      // write
      case (ws)
        W_IDLE: if (w_go) begin
          w_addr <= awaddr; w_resp <= check(awaddr, awlen, awsize, awburst);
          w_wait <= latency(awaddr);
          if (check(awaddr, awlen, awsize, awburst) == 2'b00) begin
            if (latency(awaddr) == 4'(T_HIT)) stat_row_hit <= 1'b1; else stat_row_miss <= 1'b1;
            open_row[awaddr[11:10]] <= awaddr[MW-1:12]; row_ok[awaddr[11:10]] <= 1'b1;
          end
          last_was_read <= 1'b0;
          ws <= W_WAIT;
        end
        W_WAIT: if (w_wait <= 1) ws <= W_DATA; else w_wait <= w_wait - 1;
        W_DATA: if (wvalid) begin
          if (w_resp == 2'b00)
            for (int b = 0; b < 4; b++)
`ifdef BUG_WSTRB_IGNORE
              mem[w_addr[MW-1:2]][8*b +: 8] <= wdata[8*b +: 8];
`else
              if (wstrb[b]) mem[w_addr[MW-1:2]][8*b +: 8] <= wdata[8*b +: 8];
`endif
          w_addr <= w_addr + 4;
          if (wlast) ws <= W_RESP;
        end
        W_RESP: if (bready) ws <= W_IDLE;
        default: ws <= W_IDLE;
      endcase
    end
  end
endmodule
