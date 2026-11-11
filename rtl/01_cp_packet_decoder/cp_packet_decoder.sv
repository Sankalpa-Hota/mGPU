// CP packet decoder: splits a PM4 dword stream into register writes (type 4) and opcode payloads (type 7).
// One dword is consumed per accepted cycle. Payload dwords wait for out_ready (register bus / SQE backpressure).
module cp_packet_decoder (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        dw_valid,
  output logic        dw_ready,
  input  logic [31:0] dw_data,
  input  logic        out_ready,
  output logic        reg_wr_en,
  output logic [17:0] reg_wr_addr,
  output logic [31:0] reg_wr_data,
  output logic        op_valid,
  output logic [6:0]  op_code,
  output logic [31:0] op_data,
  output logic        op_last,
  output logic        bad_pkt,
  output logic        busy
);
  typedef enum logic [1:0] {S_HDR, S_T4, S_T7} state_t;
  state_t      state;
  logic [13:0] remain;
  logic [17:0] cur_reg;
  logic [6:0]  cur_op;
  logic        take;

  assign dw_ready = (state == S_HDR) ? 1'b1 : out_ready;
  assign take     = dw_valid && dw_ready;

  assign reg_wr_en   = take && (state == S_T4);
  assign reg_wr_addr = cur_reg;
  assign reg_wr_data = dw_data;
  assign op_valid    = take && (state == S_T7);
  assign op_code     = cur_op;
  assign op_data     = dw_data;
  assign op_last     = op_valid && (remain == 14'd1);
  assign busy        = (state != S_HDR);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= S_HDR;
      remain  <= '0;
      cur_reg <= '0;
      cur_op  <= '0;
      bad_pkt <= 1'b0;
    end else if (take) begin
      case (state)
        S_HDR: begin
          if (dw_data[31:28] == 4'h4) begin
            cur_reg <= dw_data[25:8];
            remain  <= {7'd0, dw_data[6:0]};
`ifdef BUG_ZERO_COUNT
            state   <= S_T4;
`else
            state   <= (dw_data[6:0] == 7'd0) ? S_HDR : S_T4;
`endif
          end else if (dw_data[31:28] == 4'h7) begin
            cur_op  <= dw_data[22:16];
            remain  <= dw_data[13:0];
            state   <= (dw_data[13:0] == 14'd0) ? S_HDR : S_T7;
          end else begin
            bad_pkt <= 1'b1;
          end
        end
        S_T4: begin
`ifndef BUG_T4_NOINC
          cur_reg <= cur_reg + 18'd1;
`endif
          remain  <= remain - 14'd1;
          if (remain == 14'd1) state <= S_HDR;
        end
        S_T7: begin
          remain <= remain - 14'd1;
          if (remain == 14'd1) state <= S_HDR;
        end
        default: state <= S_HDR;
      endcase
    end
  end
endmodule
