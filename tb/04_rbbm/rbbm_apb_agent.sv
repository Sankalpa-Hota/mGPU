// APB master: setup phase (psel=1, penable=0), then access phase (penable=1) until pready.
class rbbm_apb_driver extends uvm_driver #(apb_item);
  `uvm_component_utils(rbbm_apb_driver)
  rbbm_vif_t vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(rbbm_vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "no vif")
  endfunction
  task run_phase(uvm_phase phase);
    vif.psel = 0; vif.penable = 0; vif.pwrite = 0; vif.paddr = 0; vif.pwdata = 0;
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    forever begin
      seq_item_port.get_next_item(req);
      vif.psel = 1; vif.penable = 0;
      vif.paddr = req.addr; vif.pwrite = req.write; vif.pwdata = req.wdata;
      @(posedge vif.clk); #1;
      vif.penable = 1;
      do @(negedge vif.clk); while (!vif.pready);
      req.rdata  = vif.prdata;
      req.slverr = vif.pslverr;
      @(posedge vif.clk); #1;
      vif.psel = 0; vif.penable = 0;
      `uvm_info("APB", req.convert2string(), UVM_HIGH)
      seq_item_port.item_done();
    end
  endtask
endclass

class rbbm_apb_monitor extends uvm_monitor;
  `uvm_component_utils(rbbm_apb_monitor)
  rbbm_vif_t vif;
  uvm_analysis_port #(apb_item) ap;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    void'(uvm_config_db#(rbbm_vif_t)::get(this, "", "vif", vif));
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n === 1 && vif.psel && vif.penable && vif.pready) begin
        apb_item t = apb_item::type_id::create("t");
        t.addr = vif.paddr; t.write = vif.pwrite; t.wdata = vif.pwdata;
        t.rdata = vif.prdata; t.slverr = vif.pslverr;
        ap.write(t);
      end
    end
  endtask
endclass

class rbbm_apb_agent extends uvm_agent;
  `uvm_component_utils(rbbm_apb_agent)
  uvm_sequencer #(apb_item) sqr;
  rbbm_apb_driver  drv;
  rbbm_apb_monitor mon;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = uvm_sequencer#(apb_item)::type_id::create("sqr", this);
    drv = rbbm_apb_driver::type_id::create("drv", this);
    mon = rbbm_apb_monitor::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
