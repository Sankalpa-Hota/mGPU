// Dispatcher: turns one DISPATCH (N workgroups) into N workgroup launches.
// Kernel configuration registers (written by the CP register bus):
//   0x100 KERNEL_PC     first instruction (byte address)
//   0x101 WARPS_PER_WG  warps in each workgroup, 1..4 (0 is treated as 1, above 4 as 4)
//   0x102 ARG_BASE      address of the kernel argument block
// A workgroup always runs on one sub-core (a "slot"); slot s is SM (s % NSM), sub-core (s / NSM).
// The configuration is latched when the DISPATCH is accepted, so the driver may program the next kernel
// while this one is still launching.
module dispatcher #(
  parameter int NSM   = 2,
  parameter int NSUB  = 2,
  localparam int NSLOT = NSM * NSUB,
  localparam int SW    = $clog2(NSLOT)
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             reg_wr_en,
  input  logic [17:0]      reg_wr_addr,
  input  logic [31:0]      reg_wr_data,
  input  logic             disp_valid,
  output logic             disp_ready,
  input  logic [31:0]      disp_num_wg,
  output logic             launch_valid,
  output logic [SW-1:0]    launch_slot,
  output logic [31:0]      launch_wg_id,
  output logic [2:0]       launch_nwarps,
  output logic [31:0]      launch_pc,
  output logic [31:0]      launch_arg,
  input  logic [NSLOT-1:0] wg_done,
  input  logic [NSM-1:0]   sm_avail,
  output logic [NSM-1:0]   sm_want,
  output logic             busy
);
  logic [31:0] cfg_pc, cfg_arg;
  logic [2:0]  cfg_nw;
  logic [31:0] k_pc, k_arg;
  logic [2:0]  k_nw;
  logic [31:0] remaining, next_wg;
  logic [NSLOT-1:0] occ;
  logic [SW-1:0] rr;

  assign disp_ready = (remaining == 0);

  // pick the first free, available slot at or after the round-robin pointer
  logic          found;
  logic [SW-1:0] pick;
  always_comb begin
    found = 1'b0;
    pick  = '0;
    for (int k = 0; k < NSLOT; k++) begin
      logic [SW-1:0] s;
      s = SW'(rr + k);
`ifdef BUG_IGNORE_AVAIL
      if (!found && !occ[s]) begin
`else
      if (!found && !occ[s] && sm_avail[s % NSM]) begin
`endif
        found = 1'b1;
        pick  = s;
      end
    end
  end

  assign launch_valid  = (remaining != 0) && found;
  assign launch_slot   = pick;
  assign launch_wg_id  = next_wg;
`ifdef BUG_LIVE_CONFIG
  assign launch_nwarps = cfg_nw;
  assign launch_pc     = cfg_pc;
  assign launch_arg    = cfg_arg;
`else
  assign launch_nwarps = k_nw;
  assign launch_pc     = k_pc;
  assign launch_arg    = k_arg;
`endif

`ifdef BUG_BUSY_EARLY
  assign busy = (remaining != 0);
`else
  assign busy = (remaining != 0) || (|occ);
`endif

  always_comb
    for (int m = 0; m < NSM; m++) begin
      sm_want[m] = (remaining != 0);
      for (int u = 0; u < NSUB; u++) if (occ[u * NSM + m]) sm_want[m] = 1'b1;
    end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg_pc <= '0; cfg_arg <= '0; cfg_nw <= 3'd1;
      k_pc <= '0; k_arg <= '0; k_nw <= 3'd1;
      remaining <= '0; next_wg <= '0; occ <= '0; rr <= '0;
    end else begin
      if (reg_wr_en) case (reg_wr_addr)
        18'h100: cfg_pc  <= reg_wr_data;
        18'h101: cfg_nw  <= (reg_wr_data == 0) ? 3'd1 : (reg_wr_data > 4) ? 3'd4 : reg_wr_data[2:0];
        18'h102: cfg_arg <= reg_wr_data;
        default: ;
      endcase
      if (disp_valid && disp_ready) begin
        remaining <= disp_num_wg;
        next_wg   <= '0;
        k_pc      <= cfg_pc;
        k_arg     <= cfg_arg;
        k_nw      <= cfg_nw;
      end else if (launch_valid) begin
        remaining <= remaining - 1;
        next_wg   <= next_wg + 1;
        rr        <= SW'(pick + 1);
      end
      occ <= (occ & ~wg_done) | (launch_valid ? (NSLOT'(1) << pick) : '0);
    end
  end
endmodule
