// RBBM: the CPU's register port into the GPU (APB slave, zero wait states).
//
//  offset  name          access  meaning
//  0x000   ID            RO      0x6D475055 ("mGPU")
//  0x004   RING_BASE     RW      byte address of the command ring (bits [4:0] read as 0)
//  0x008   RING_WPTR     RW      write pointer, driven to the CP
//  0x00C   RING_RPTR     RO      read pointer reported by the CP
//  0x010   IRQ_STATUS    W1C     bit0 fence, bit1 bad packet, bit2 bad op, bit3 hang
//  0x014   IRQ_MASK      RW      irq = |(IRQ_STATUS & IRQ_MASK)
//  0x018   BUSY_STATUS   RO      live busy bits of the blocks
//  0x01C   HANG_TIMEOUT  RW      cycles busy without progress before the hang bit is set (0 = off)
//  0x020   SOFT_RESET    WO      write bit0 = 1: one-cycle soft reset pulse to the GPU (reads 0)
//  0x040+8i PERF_SEL[i]  RW      event number counted by counter i (i = 0..3)
//  0x044+8i PERF_CNT[i]  RW      counter value; counts +1 every cycle the selected event is high; write sets it
// Any other offset, or a write to a read-only register, completes with PSLVERR = 1 and changes nothing.
// A hardware event and a W1C clear of the same status bit in the same cycle: the event wins (it is never lost).
module rbbm #(
  parameter int RING_LOG2 = 10,
  parameter int NBUSY     = 8,
  parameter int NEV       = 16
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 psel,
  input  logic                 penable,
  input  logic                 pwrite,
  input  logic [11:0]          paddr,
  input  logic [31:0]          pwdata,
  output logic [31:0]          prdata,
  output logic                 pready,
  output logic                 pslverr,
  output logic [31:0]          ring_base,
  output logic [RING_LOG2-1:0] ring_wptr,
  input  logic [RING_LOG2-1:0] ring_rptr,
  input  logic                 ev_fence,     // SQE irq pulse
  input  logic                 ev_bad_pkt,   // decoder sticky flag
  input  logic                 ev_bad_op,    // SQE sticky flag
  input  logic [NBUSY-1:0]     busy_in,
  input  logic                 progress,     // pulse whenever the GPU makes forward progress
  input  logic [NEV-1:0]       perf_ev,
  output logic                 irq,
  output logic                 soft_reset
);
  logic [3:0]  irq_status, irq_mask;
  logic [31:0] hang_timeout, hang_cnt;
  logic [3:0]  perf_sel [4];
  logic [31:0] perf_cnt [4];
  logic        bad_pkt_q, bad_op_q;

  logic access, wr, rd;
  assign pready = 1'b1;
  assign access = psel && penable;
  assign wr     = access && pwrite;
  assign rd     = access && !pwrite;

  // address decode
  logic known, ro;
  always_comb begin
    known = 1'b1;
    ro    = 1'b0;
    case (paddr)
      12'h000, 12'h00C, 12'h018: ro = 1'b1;
      12'h004, 12'h008, 12'h010, 12'h014, 12'h01C, 12'h020: ;
      12'h040, 12'h044, 12'h048, 12'h04C, 12'h050, 12'h054, 12'h058, 12'h05C: ;
      default: known = 1'b0;
    endcase
  end
  assign pslverr = access && (!known || (pwrite && ro));
  logic wr_ok;
  assign wr_ok = wr && known && !ro;

  always_comb begin
    prdata = '0;
    if (rd) case (paddr)
      12'h000: prdata = 32'h6D47_5055;
      12'h004: prdata = ring_base;
      12'h008: prdata = 32'(ring_wptr);
      12'h00C: prdata = 32'(ring_rptr);
      12'h010: prdata = {28'd0, irq_status};
      12'h014: prdata = {28'd0, irq_mask};
      12'h018: prdata = 32'(busy_in);
      12'h01C: prdata = hang_timeout;
      12'h040: prdata = {28'd0, perf_sel[0]};
      12'h044: prdata = perf_cnt[0];
      12'h048: prdata = {28'd0, perf_sel[1]};
      12'h04C: prdata = perf_cnt[1];
      12'h050: prdata = {28'd0, perf_sel[2]};
      12'h054: prdata = perf_cnt[2];
      12'h058: prdata = {28'd0, perf_sel[3]};
      12'h05C: prdata = perf_cnt[3];
      default: prdata = '0;
    endcase
  end

  // interrupt sources: pulse for the fence, rising edge for the sticky error flags
  logic hang_set;
  logic [3:0] hw_set;
  assign hw_set = {hang_set, ev_bad_op && !bad_op_q, ev_bad_pkt && !bad_pkt_q, ev_fence};

  logic [3:0] w1c;
  assign w1c = (wr_ok && paddr == 12'h010) ? pwdata[3:0] : 4'd0;

  assign irq = |(irq_status & irq_mask);

  // hang detector: count cycles where something is busy and nothing progresses
  logic any_busy;
  assign any_busy = |busy_in;
  `ifdef BUG_HANG_IGNORES_PROGRESS
  assign hang_set = (hang_timeout != 0) && (hang_cnt == hang_timeout - 1) && any_busy;
`else
  assign hang_set = (hang_timeout != 0) && (hang_cnt == hang_timeout - 1) && any_busy && !progress;
`endif

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ring_base    <= '0;
      ring_wptr    <= '0;
      irq_status   <= '0;
      irq_mask     <= '0;
      hang_timeout <= '0;
      hang_cnt     <= '0;
      soft_reset   <= 1'b0;
      bad_pkt_q    <= 1'b0;
      bad_op_q     <= 1'b0;
      for (int i = 0; i < 4; i++) begin
        perf_sel[i] <= '0;
        perf_cnt[i] <= '0;
      end
    end else begin
      bad_pkt_q  <= ev_bad_pkt;
      bad_op_q   <= ev_bad_op;
      soft_reset <= wr_ok && paddr == 12'h020 && pwdata[0];

      if (wr_ok && paddr == 12'h004) ring_base    <= {pwdata[31:5], 5'd0};
      if (wr_ok && paddr == 12'h008) ring_wptr    <= pwdata[RING_LOG2-1:0];
      if (wr_ok && paddr == 12'h014) irq_mask     <= pwdata[3:0];
      if (wr_ok && paddr == 12'h01C) hang_timeout <= pwdata;

`ifdef BUG_W1C_LOSES_SET
      irq_status <= (irq_status | hw_set) & ~w1c;
`else
      irq_status <= (irq_status & ~w1c) | hw_set;
`endif

`ifdef BUG_HANG_IGNORES_PROGRESS
      if (!any_busy || hang_timeout == 0) hang_cnt <= '0;
`else
      if (!any_busy || progress || hang_timeout == 0) hang_cnt <= '0;
`endif
      else if (hang_cnt != hang_timeout - 1) hang_cnt <= hang_cnt + 1;
      else hang_cnt <= '0;

      for (int i = 0; i < 4; i++) begin
        if (wr_ok && paddr == 12'(12'h040 + 8 * i)) perf_sel[i] <= pwdata[3:0];
`ifdef BUG_PERF_WRITE_LOST
        if (perf_ev[perf_sel[i]]) perf_cnt[i] <= perf_cnt[i] + 1;
        else if (wr_ok && paddr == 12'(12'h044 + 8 * i)) perf_cnt[i] <= pwdata;
`else
        if (wr_ok && paddr == 12'(12'h044 + 8 * i)) perf_cnt[i] <= pwdata;
        else if (perf_ev[perf_sel[i]]) perf_cnt[i] <= perf_cnt[i] + 1;
`endif
      end
    end
  end
endmodule
