// mGPU plus its DRAM: the whole system a CPU sees (APB registers, interrupt, memory).
module mgpu_system (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  input  logic [11:0] paddr,
  input  logic [31:0] pwdata,
  output logic [31:0] prdata,
  output logic        pready,
  output logic        pslverr,
  output logic        irq,
  output logic        mmu_fault,
  output logic [31:0] mmu_fault_va
);
  logic [31:0] araddr, rdata, awaddr, wdata;
  logic [7:0]  arlen, awlen;
  logic [2:0]  arsize, awsize;
  logic [1:0]  arburst, awburst, rresp, bresp;
  logic        arvalid, arready, rlast, rvalid, rready, awvalid, awready, wlast, wvalid, wready, bvalid, bready;
  logic [3:0]  wstrb;
  logic        row_hit, row_miss;

  mgpu_top u_gpu (
    .clk(clk), .rst_n(rst_n), .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready), .pslverr(pslverr), .irq(irq), .mmu_fault(mmu_fault), .mmu_fault_va(mmu_fault_va),
    .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .dram_perf({14'd0, row_miss, row_hit}));

  dram_ctrl #(.MW(20), .T_HIT(2), .T_MISS(8)) u_dram (
    .clk(clk), .rst_n(rst_n),
    .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .stat_row_hit(row_hit), .stat_row_miss(row_miss));
endmodule
