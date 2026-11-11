interface top_interface (input logic clk, input logic rst_n);
  logic        psel, penable, pwrite, pready, pslverr, irq, mmu_fault;
  logic [11:0] paddr;
  logic [31:0] pwdata, prdata, mmu_fault_va;
endinterface
