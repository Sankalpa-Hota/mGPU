interface mmu_interface (input logic clk, input logic rst_n);
  logic         enable, tlb_invalidate, fault_clear, fault_valid, fault_write, stat_tlb_hit, stat_walk;
  logic [31:0]  ptbr, fault_va;
  logic         req_valid, req_ready, req_we, rsp_valid, rsp_err;
  logic [31:0]  req_addr, req_wstrb;
  logic [255:0] req_wdata, rsp_data;
  logic         mreq_valid, mreq_ready, mreq_we, mrsp_valid;
  logic [31:0]  mreq_addr, mreq_wstrb;
  logic [255:0] mreq_wdata, mrsp_data;
endinterface
