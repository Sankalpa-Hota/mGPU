class apb_item extends uvm_sequence_item;
  `uvm_object_utils(apb_item)
  rand bit [11:0] addr;
  rand bit        write;
  rand bit [31:0] wdata;
  bit [31:0]      rdata;
  bit             slverr;
  constraint c_align { addr[1:0] == 0; }
  function new(string name = "apb_item");
    super.new(name);
  endfunction
  function string convert2string();
    return write ? $sformatf("APB WR %03h = %08h%s", addr, wdata, slverr ? " SLVERR" : "")
                 : $sformatf("APB RD %03h -> %08h%s", addr, rdata, slverr ? " SLVERR" : "");
  endfunction
endclass
