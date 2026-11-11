// GBIF: the GPU's bus interface. Turns one line request (32 bytes) into one AXI4 burst on a 32-bit bus.
//   read : AR (len 7 = 8 beats, size 2 = 4 bytes, INCR), collect 8 R beats into the line
//   write: AW and W are driven at the same time (AXI forbids waiting for AWREADY before WVALID, because a slave
//          may wait for write data before accepting the address); 8 W beats with the line's byte strobes,
//          WLAST on the 8th; then wait for B
//   Any RRESP / BRESP other than OKAY answers the request with err = 1.
// One transaction at a time, ID 0.
module gbif (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         req_valid,
  output logic         req_ready,
  input  logic [31:0]  req_addr,
  input  logic         req_we,
  input  logic [255:0] req_wdata,
  input  logic [31:0]  req_wstrb,
  output logic         rsp_valid,
  output logic [255:0] rsp_data,
  output logic         rsp_err,
  // AXI4 master
  output logic [31:0]  araddr,
  output logic [7:0]   arlen,
  output logic [2:0]   arsize,
  output logic [1:0]   arburst,
  output logic         arvalid,
  input  logic         arready,
  input  logic [31:0]  rdata,
  input  logic [1:0]   rresp,
  input  logic         rlast,
  input  logic         rvalid,
  output logic         rready,
  output logic [31:0]  awaddr,
  output logic [7:0]   awlen,
  output logic [2:0]   awsize,
  output logic [1:0]   awburst,
  output logic         awvalid,
  input  logic         awready,
  output logic [31:0]  wdata,
  output logic [3:0]   wstrb,
  output logic         wlast,
  output logic         wvalid,
  input  logic         wready,
  input  logic [1:0]   bresp,
  input  logic         bvalid,
  output logic         bready
);
  typedef enum logic [2:0] {S_IDLE, S_AR, S_R, S_W, S_B, S_DONE} state_t;
  state_t state;
  logic [31:0]  c_addr;
  logic [255:0] c_wdata, line;
  logic [31:0]  c_wstrb;
  logic [2:0]   beat;
  logic         aw_done, w_done, err;

  assign req_ready = (state == S_IDLE);
  assign arlen = 8'd7;   assign arsize = 3'd2; assign arburst = 2'b01;
  assign awlen = 8'd7;   assign awsize = 3'd2; assign awburst = 2'b01;
  assign araddr  = c_addr;
  assign awaddr  = c_addr;
  assign arvalid = (state == S_AR);
  assign rready  = (state == S_R);
  assign awvalid = (state == S_W) && !aw_done;
`ifdef BUG_W_AFTER_AW
  assign wvalid  = (state == S_W) && !w_done && aw_done;    // waits for AWREADY first: can deadlock
`else
  assign wvalid  = (state == S_W) && !w_done;
`endif
  assign wdata   = c_wdata[32*beat +: 32];
  assign wstrb   = c_wstrb[4*beat +: 4];
`ifdef BUG_WLAST
  assign wlast   = (beat == 3'd6);
`else
  assign wlast   = (beat == 3'd7);
`endif
  assign bready  = (state == S_B);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE; rsp_valid <= 1'b0; rsp_err <= 1'b0; beat <= '0; aw_done <= 1'b0; w_done <= 1'b0; err <= 1'b0;
    end else begin
      rsp_valid <= 1'b0;
      case (state)
        S_IDLE: if (req_valid) begin
          c_addr <= {req_addr[31:5], 5'd0}; c_wdata <= req_wdata; c_wstrb <= req_wstrb;
          beat <= '0; aw_done <= 1'b0; w_done <= 1'b0; err <= 1'b0;
          state <= req_we ? S_W : S_AR;
        end
        S_AR: if (arready) state <= S_R;
        S_R: if (rvalid) begin
`ifdef BUG_RBEAT_ORDER
          line[32*(7-beat) +: 32] <= rdata;
`else
          line[32*beat +: 32] <= rdata;
`endif
          if (rresp != 2'b00) err <= 1'b1;
          beat <= beat + 1;
          if (beat == 3'd7) state <= S_DONE;
        end
        S_W: begin
          logic aw_now, w_now;
          aw_now = aw_done || (awvalid && awready);
          w_now  = w_done || (wvalid && wready && beat == 3'd7);
          if (awvalid && awready) aw_done <= 1'b1;
          if (wvalid && wready) begin
            beat <= beat + 1;
            if (beat == 3'd7) w_done <= 1'b1;
          end
          if (aw_now && w_now) state <= S_B;
        end
        S_B: if (bvalid) begin
          if (bresp != 2'b00) err <= 1'b1;
          state <= S_DONE;
        end
        S_DONE: begin
          rsp_valid <= 1'b1;
          rsp_data  <= line;
          rsp_err   <= err;
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
