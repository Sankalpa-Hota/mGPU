// One monitor samples input and output in the same negedge, input first, so the scoreboard always gets the
// dword that caused an output before the output itself.
class cp_monitor extends uvm_monitor;
  `uvm_component_utils(cp_monitor)
  virtual cp_if vif;
  uvm_analysis_port #(cp_dw_item)  in_ap;
  uvm_analysis_port #(cp_out_item) out_ap;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    in_ap  = new("in_ap", this);
    out_ap = new("out_ap", this);
    if (!uvm_config_db#(virtual cp_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "no vif")
  endfunction
  task run_phase(uvm_phase phase);
    bit waited = 0;
    bit bad_q  = 0;
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) begin bad_q = 0; waited = 0; continue; end
      if (vif.bad_pkt && !bad_q) begin
        cp_out_item o = cp_out_item::type_id::create("o");
        o.kind = OUT_BAD;
        out_ap.write(o);
      end
      bad_q = vif.bad_pkt;
      if (vif.dw_valid && vif.dw_ready) begin
        cp_dw_item d = cp_dw_item::type_id::create("d");
        d.data = vif.dw_data;
        d.stalled = waited;
        in_ap.write(d);
        waited = 0;
      end else if (vif.dw_valid) begin
        waited = 1;
      end
      if (vif.reg_wr_en) begin
        cp_out_item o = cp_out_item::type_id::create("o");
        o.kind = OUT_REG; o.addr = vif.reg_wr_addr; o.data = vif.reg_wr_data;
        out_ap.write(o);
      end
      if (vif.op_valid) begin
        cp_out_item o = cp_out_item::type_id::create("o");
        o.kind = OUT_OP; o.op = vif.op_code; o.data = vif.op_data; o.last = vif.op_last;
        out_ap.write(o);
      end
    end
  endtask
endclass
