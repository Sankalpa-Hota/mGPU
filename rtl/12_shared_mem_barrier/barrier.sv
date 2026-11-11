// Workgroup barrier of one sub-core (one workgroup per sub-core).
// A warp that executes BAR arrives and waits. When every warp of the workgroup that is still alive has
// arrived, all waiting warps are released together (release_mask pulse) and the barrier is ready for the next
// use. Warps that already exited do not count: otherwise one early EXIT would deadlock the others.
// The check is made every cycle, so a warp exiting can be the event that releases the others.
module barrier #(
  parameter int NW = 4
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic [NW-1:0] wl_mask,       // workgroup launch: barrier state cleared
  input  logic          arrive_valid,
  input  logic [$clog2(NW)-1:0] arrive_warp,
  input  logic [NW-1:0] live,          // warps of this workgroup that have not exited
  output logic [NW-1:0] release_mask,
  output logic [NW-1:0] waiting
);
  logic [NW-1:0] arrived, now, members;
  always_comb begin
    now = arrived;
    if (arrive_valid) now[arrive_warp] = 1'b1;
  end
  logic all_in;
`ifdef BUG_COUNT_EXITED
  assign all_in = (now != '0) && ((members & ~now) == '0);    // waits for exited warps too
`else
  assign all_in = (now != '0) && ((live & ~now) == '0);
`endif
  assign waiting = arrived;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      arrived <= '0;
      members <= '0;
      release_mask <= '0;
    end else begin
      if (wl_mask != '0) members <= wl_mask;
      release_mask <= '0;
      if (wl_mask != '0) arrived <= '0;
      else if (all_in) begin
        release_mask <= now;
`ifndef BUG_NO_CLEAR
        arrived <= '0;
`endif
      end else arrived <= now;
    end
  end
endmodule
