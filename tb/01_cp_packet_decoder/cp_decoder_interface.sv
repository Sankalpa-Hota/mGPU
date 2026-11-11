interface cp_if (input logic clk, input logic rst_n);
  logic        dw_valid;
  logic        dw_ready;
  logic [31:0] dw_data;
  logic        out_ready;
  logic        reg_wr_en;
  logic [17:0] reg_wr_addr;
  logic [31:0] reg_wr_data;
  logic        op_valid;
  logic [6:0]  op_code;
  logic [31:0] op_data;
  logic        op_last;
  logic        bad_pkt;
  logic        busy;
endinterface
