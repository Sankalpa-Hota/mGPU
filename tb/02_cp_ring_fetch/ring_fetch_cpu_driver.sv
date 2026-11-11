// Plays the CPU driver software: write the new dwords into the ring in memory, then publish the new WPTR.
// Like real software it never lets WPTR catch up with RPTR from behind (one slot always stays free).
class ring_fetch_cpu_driver extends uvm_driver #(ring_cmd);
  `uvm_component_utils(ring_fetch_cpu_driver)
  ring_vif_t vif;
  ring_fetch_config cfg;
  ring_memory mem;
  bit [RING_LOG2-1:0] wptr;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(ring_vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "no vif")
    if (!uvm_config_db#(ring_fetch_config)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "no cfg")
    if (!uvm_config_db#(ring_memory)::get(this, "", "mem", mem)) `uvm_fatal("NOMEM", "no mem")
  endfunction
  function int free_slots();
    return RING_SIZE - 1 - int'(RING_LOG2'(wptr - vif.rptr));
  endfunction
  task run_phase(uvm_phase phase);
    vif.ring_base = cfg.ring_base;
    vif.wptr = '0;
    wptr = '0;
    wait (vif.rst_n === 1);
    forever begin
      int done = 0;
      seq_item_port.get_next_item(req);
      repeat (req.gap) @(posedge vif.clk);
      while (done < req.n) begin
        int k;
        while (free_slots() == 0) @(posedge vif.clk);
        k = free_slots();
        if (k > req.n - done) k = req.n - done;
        for (int i = 0; i < k; i++) begin
          mem.dw[cfg.ring_base + 4 * int'(wptr)] = req.data[done + i];
          wptr++;
        end
        done += k;
        @(posedge vif.clk); #1;
        vif.wptr = wptr;
      end
      seq_item_port.item_done();
    end
  endtask
endclass
