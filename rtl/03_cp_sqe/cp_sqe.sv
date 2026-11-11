// SQE: executes type 7 operations delivered by the packet decoder.
//   0x01 DISPATCH       arg0 = number of workgroups     -> one dispatch request to the dispatcher
//   0x02 EVENT_WRITE    arg0 = byte address, arg1 = value -> one masked memory write, then a one-cycle IRQ after the write ack
//   0x03 WAIT_FOR_IDLE  arg0 = busy-bit mask             -> wait until every selected busy bit is low
// Unknown opcodes take one cycle in S_DROP, set the sticky bad_op flag and do nothing else. Payload dwords beyond the first two are ignored.
// Busy contract: a block raises its busy bit no later than SETTLE cycles after it accepts work.
module cp_sqe #(
  parameter int NBUSY  = 8,
  parameter int SETTLE = 3
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             op_valid,
  output logic             op_ready,
  input  logic [6:0]       op_code,
  input  logic [31:0]      op_data,
  input  logic             op_last,
  output logic             disp_valid,
  input  logic             disp_ready,
  output logic [31:0]      disp_num_wg,
  input  logic [NBUSY-1:0] busy_in,
  output logic             mreq_valid,
  input  logic             mreq_ready,
  output logic [31:0]      mreq_addr,
  output logic             mreq_we,
  output logic [255:0]     mreq_wdata,
  output logic [31:0]      mreq_wstrb,
  input  logic             mrsp_valid,
  output logic             irq,
  output logic             op_done,
  output logic             bad_op,
  output logic             busy
);
  typedef enum logic [2:0] {S_COLLECT, S_DISPATCH, S_WFI_SETTLE, S_WFI, S_EW_REQ, S_EW_ACK, S_DROP} state_t;
  state_t state;

  logic [6:0]  op_q;
  logic [31:0] arg0, arg1;
  logic [1:0]  n_args;
  logic [1:0]  settle_cnt;

  assign op_ready    = (state == S_COLLECT);
  assign disp_valid  = (state == S_DISPATCH);
  assign disp_num_wg = arg0;
  assign mreq_valid  = (state == S_EW_REQ);
  assign mreq_addr   = {arg0[31:5], 5'b00000};
  assign mreq_we     = 1'b1;
  assign mreq_wdata  = {8{arg1}};
`ifdef BUG_STRB
  assign mreq_wstrb  = 32'hF << (4 * arg0[3:2]);
`else
  assign mreq_wstrb  = 32'hF << (4 * arg0[4:2]);
`endif
  assign busy        = (state != S_COLLECT) || (n_args != 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_COLLECT;
      op_q       <= '0;
      arg0       <= '0;
      arg1       <= '0;
      n_args     <= '0;
      settle_cnt <= '0;
      irq        <= 1'b0;
      op_done    <= 1'b0;
      bad_op     <= 1'b0;
    end else begin
      irq     <= 1'b0;
      op_done <= 1'b0;
      case (state)
        S_COLLECT: if (op_valid) begin
          if (n_args == 0) arg0 <= op_data;
          if (n_args == 1) arg1 <= op_data;
          if (n_args != 2'd2) n_args <= n_args + 1'b1;
          op_q <= op_code;
          if (op_last) begin
            n_args <= '0;
            case (op_code)
              7'h01: state <= S_DISPATCH;
              7'h02: state <= S_EW_REQ;
`ifdef BUG_WFI_NO_SETTLE
              7'h03: state <= S_WFI;
`else
              7'h03: begin state <= S_WFI_SETTLE; settle_cnt <= '0; end
`endif
              default: state <= S_DROP;
            endcase
          end
        end
        S_DISPATCH: if (disp_ready) begin
          state   <= S_COLLECT;
          op_done <= 1'b1;
        end
        S_WFI_SETTLE: begin
          settle_cnt <= settle_cnt + 1'b1;
          if (settle_cnt == 2'(SETTLE - 1)) state <= S_WFI;
        end
        S_WFI: if ((busy_in & arg0[NBUSY-1:0]) == '0) begin
          state   <= S_COLLECT;
          op_done <= 1'b1;
        end
        S_EW_REQ: if (mreq_ready) begin
          state <= S_EW_ACK;
`ifdef BUG_IRQ_BEFORE_ACK
          irq   <= 1'b1;
`endif
        end
        S_EW_ACK: if (mrsp_valid) begin
`ifndef BUG_IRQ_BEFORE_ACK
          irq     <= 1'b1;
`endif
          op_done <= 1'b1;
          state   <= S_COLLECT;
        end
        S_DROP: begin
          bad_op  <= 1'b1;
          op_done <= 1'b1;
          state   <= S_COLLECT;
        end
        default: state <= S_COLLECT;
      endcase
    end
  end
endmodule
