// Watches three things: WPTR moves (new work), memory requests (with latency), and delivered dwords.
class ring_fetch_monitor extends uvm_monitor;
  `uvm_component_utils(ring_fetch_monitor)
  ring_vif_t vif;
  ring_fetch_config cfg;
  ring_memory mem;
  uvm_analysis_port #(ring_wptr_item) wptr_ap;
  uvm_analysis_port #(ring_req_item)  req_ap;
  uvm_analysis_port #(ring_dw_item)   dw_ap;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    wptr_ap = new("wptr_ap", this);
    req_ap  = new("req_ap", this);
    dw_ap   = new("dw_ap", this);
    void'(uvm_config_db#(ring_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(ring_fetch_config)::get(this, "", "cfg", cfg));
    void'(uvm_config_db#(ring_memory)::get(this, "", "mem", mem));
  endfunction
  task run_phase(uvm_phase phase);
    bit [RING_LOG2-1:0] last_wptr = '0;
    ring_req_item open_req;
    int lat;
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      if (vif.wptr != last_wptr) begin
        ring_wptr_item w = ring_wptr_item::type_id::create("w");
        w.old_wptr = last_wptr;
        w.new_wptr = vif.wptr;
        w.wrapped  = (vif.wptr < last_wptr);
        w.req_in_flight = (open_req != null);
        for (bit [RING_LOG2-1:0] p = last_wptr; p != vif.wptr; p++)
          w.data.push_back(mem.read(cfg.ring_base + 4 * int'(p)));
        wptr_ap.write(w);
        last_wptr = vif.wptr;
      end
      if (open_req != null) begin
        lat++;
        if (vif.mrsp_valid) begin
          open_req.latency = lat;
          req_ap.write(open_req);
          open_req = null;
        end
      end
      if (vif.mreq_valid && vif.mreq_ready) begin
        open_req = ring_req_item::type_id::create("r");
        open_req.addr = vif.mreq_addr;
        open_req.wptr_at_issue = vif.wptr;
        open_req.rptr_at_issue = vif.rptr;
        lat = 0;
      end
      if (vif.dw_valid && vif.dw_ready) begin
        ring_dw_item d = ring_dw_item::type_id::create("d");
        d.data = vif.dw_data;
        d.rptr_before = vif.rptr;
        dw_ap.write(d);
      end
    end
  endtask
endclass
