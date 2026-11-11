// GMU (graphics management unit): power control of the SMs.
// Per SM a small state machine:
//   ON      : powered, available to the dispatcher (sm_avail = 1)
//   ON -> OFF     after idle_limit consecutive cycles with the SM not busy and not wanted by the dispatcher
//   OFF     : power gated (sm_power = 0), not available
//   OFF -> WAKING when the dispatcher wants the SM
//   WAKING  : powered but not yet usable for wake_cycles cycles (power ramp, clock start); not available
//   WAKING -> ON
// An SM is never switched off while busy. idle_limit = 0 disables power gating (always ON).
module gmu #(
  parameter int NSM = 2,
  parameter int WAKE_CYCLES = 6
) (
  input  logic           clk,
  input  logic           rst_n,
  input  logic [15:0]    idle_limit,
  input  logic [NSM-1:0] sm_busy,
  input  logic [NSM-1:0] sm_want,
  output logic [NSM-1:0] sm_avail,
  output logic [NSM-1:0] sm_power,
  output logic [NSM-1:0] stat_off_pulse,
  output logic [NSM-1:0] stat_wake_pulse
);
  typedef enum logic [1:0] {P_ON, P_OFF, P_WAKING} pstate_t;
  pstate_t   st   [NSM];
  logic [15:0] idle [NSM];
  logic [3:0]  wake [NSM];

  always_comb
    for (int m = 0; m < NSM; m++) begin
`ifdef BUG_AVAIL_EARLY
      sm_avail[m] = (st[m] != P_OFF);
`else
      sm_avail[m] = (st[m] == P_ON);
`endif
      sm_power[m] = (st[m] != P_OFF);
    end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int m = 0; m < NSM; m++) begin st[m] <= P_ON; idle[m] <= '0; wake[m] <= '0; end
      stat_off_pulse <= '0; stat_wake_pulse <= '0;
    end else begin
      stat_off_pulse <= '0; stat_wake_pulse <= '0;
      for (int m = 0; m < NSM; m++)
        case (st[m])
          P_ON: begin
`ifdef BUG_OFF_WHILE_BUSY
            if (sm_want[m] || idle_limit == 0) idle[m] <= '0;
`elsif BUG_IDLE_NO_RESET
            if (sm_busy[m]) idle[m] <= idle[m];          // pauses instead of restarting the count
            else if (sm_want[m] || idle_limit == 0) idle[m] <= '0;
`else
            if (sm_busy[m] || sm_want[m] || idle_limit == 0) idle[m] <= '0;
`endif
            else if (idle[m] == idle_limit - 1) begin
              st[m] <= P_OFF; idle[m] <= '0; stat_off_pulse[m] <= 1'b1;
            end else idle[m] <= idle[m] + 1;
          end
          P_OFF: if (sm_want[m]) begin
            st[m] <= P_WAKING; wake[m] <= 4'(WAKE_CYCLES); stat_wake_pulse[m] <= 1'b1;
          end
          P_WAKING: if (wake[m] <= 1) st[m] <= P_ON; else wake[m] <= wake[m] - 1;
          default: st[m] <= P_ON;
        endcase
    end
  end
endmodule
