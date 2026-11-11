`uvm_analysis_imp_decl(_cop)
`uvm_analysis_imp_decl(_cev)

class sqe_coverage extends uvm_component;
  `uvm_component_utils(sqe_coverage)
  uvm_analysis_imp_cop #(sqe_op,    sqe_coverage) op_imp;
  uvm_analysis_imp_cev #(sqe_event, sqe_coverage) ev_imp;
  sqe_vif_t vif;
  mgpu_coverage cov;
  sqe_op cur;
  int last_disp_t = -100, last_done_t = -100;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("sqe");
    foreach (names[i]) cov.add_bin(names[i]);
    for (int i = 0; i < 8; i++) cov.add_bin($sformatf("ew_offset_%0d", i));
  endfunction
  string names[$] = '{"op_dispatch", "op_event_write", "op_wfi", "op_unknown", "ew_extra_payload",
                      "wfi_mask_zero", "wfi_mask_all", "wfi_mask_single", "wfi_mask_other",
                      "wfi_wait_min", "wfi_wait_short", "wfi_wait_long", "wfi_right_after_dispatch",
                      "disp_backpressure", "mem_req_backpressure", "ack_fast", "ack_slow", "op_back_to_back"};
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    op_imp = new("op_imp", this);
    ev_imp = new("ev_imp", this);
    void'(uvm_config_db#(sqe_vif_t)::get(this, "", "vif", vif));
  endfunction
  function void write_cop(sqe_op o);
    cur = o;
    if (o.t_accept - last_done_t <= 2) cov.sample("op_back_to_back");
    case (o.opcode)
      7'h01: cov.sample("op_dispatch");
      7'h02: begin
        cov.sample("op_event_write");
        cov.sample($sformatf("ew_offset_%0d", o.arg0[4:2]));
        if (o.count > 2) cov.sample("ew_extra_payload");
      end
      7'h03: begin
        bit [7:0] m = o.arg0[7:0];
        cov.sample("op_wfi");
        cov.sample(m == 0 ? "wfi_mask_zero" : m == 8'hFF ? "wfi_mask_all" : $onehot(m) ? "wfi_mask_single" : "wfi_mask_other");
        if (o.t_accept - last_disp_t <= 2) cov.sample("wfi_right_after_dispatch");
      end
      default: cov.sample("op_unknown");
    endcase
  endfunction
  function void write_cev(sqe_event e);
    if (e.kind == EV_DISPATCH) last_disp_t = e.t;
    if (e.kind == EV_WRITE) cov.sample(e.t_ack - e.t <= 2 ? "ack_fast" : "ack_slow");
    if (e.kind == EV_DONE && cur != null) begin
      if (cur.opcode == 7'h03) begin
        int w = e.t - cur.t_accept;
        cov.sample(w <= SETTLE + 2 ? "wfi_wait_min" : w <= 15 ? "wfi_wait_short" : "wfi_wait_long");
      end
      last_done_t = e.t;
    end
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.disp_valid && !vif.disp_ready) cov.sample("disp_backpressure");
      if (vif.mreq_valid && !vif.mreq_ready) cov.sample("mem_req_backpressure");
    end
  endtask
  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass
