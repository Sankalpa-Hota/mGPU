class icache_memory_responder extends uvm_component;
  `uvm_component_utils(icache_memory_responder)
  icache_vif_t vif;
  icache_config cfg;
  icache_memory mem;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(icache_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(icache_config)::get(this, "", "cfg", cfg));
    void'(uvm_config_db#(icache_memory)::get(this, "", "mem", mem));
  endfunction
  task run_phase(uvm_phase phase);
    vif.mreq_ready = 0; vif.mrsp_valid = 0; vif.mrsp_data = 0;
    forever begin
      bit [31:0] a;
      @(posedge vif.clk); #1;
      vif.mreq_ready = ($urandom_range(99) < cfg.mem_rdy_pct);
      @(negedge vif.clk);
      if (!(vif.mreq_valid && vif.mreq_ready)) continue;
      a = vif.mreq_addr;
      @(posedge vif.clk); #1;
      vif.mreq_ready = 0;
      repeat ($urandom_range(cfg.mem_max_lat, cfg.mem_min_lat)) @(posedge vif.clk);
      #1;
      for (int i = 0; i < 8; i++) vif.mrsp_data[32*i +: 32] = mem.word(a + 4 * i);
      vif.mrsp_valid = 1;
      @(posedge vif.clk); #1;
      vif.mrsp_valid = 0;
    end
  endtask
endclass
