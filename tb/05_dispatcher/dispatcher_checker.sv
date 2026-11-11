// Cycle-accurate checker. Keeps its own copy of the configuration registers, the kernel being launched, the
// workgroups still to launch and which slots are occupied, and every cycle checks:
//   - a launch goes to a slot that is free and whose SM is available
//   - the launch carries the next workgroup id and the configuration latched at DISPATCH time
//   - work conserving: if work remains and a free, available slot exists, a launch happens this cycle
//   - disp_ready, busy and sm_want have their specified values
class dispatcher_checker extends uvm_component;
  `uvm_component_utils(dispatcher_checker)
  disp_vif_t vif;
  mgpu_coverage cov;
  bit [31:0] cfg_pc, cfg_arg, k_pc, k_arg, remaining, next_wg;
  bit [2:0]  cfg_nw = 1, k_nw = 1;
  bit [NSLOT-1:0] occ, freed_last;
  int n_launch, n_kernels, n_err;
  bit cfg_written_during_launch;

  string names[$] = '{"wg_count_zero", "wg_count_one", "wg_count_fits", "wg_count_queues",
                      "nwarps_1", "nwarps_2", "nwarps_3", "nwarps_4", "nwarps_clamped_low", "nwarps_clamped_high",
                      "slot_0", "slot_1", "slot_2", "slot_3", "all_slots_full_wait", "sm_asleep_wait",
                      "done_and_launch_same_cycle", "slot_reused_next_cycle", "dispatch_while_previous_running", "cfg_written_while_launching"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("dispatcher");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(disp_vif_t)::get(this, "", "vif", vif));
  endfunction
  function void err(string s);
    n_err++;
    `uvm_error("CHK", s)
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      step();
    end
  endtask

  function void step();
    bit free_avail = 0;
    bit [1:0] want = 0;
    for (int s = 0; s < NSLOT; s++) if (!occ[s] && vif.sm_avail[s % NSM]) free_avail = 1;
    for (int m = 0; m < NSM; m++) begin
      want[m] = (remaining != 0);
      for (int u = 0; u < 2; u++) if (occ[u * NSM + m]) want[m] = 1;
    end

    if (vif.disp_ready !== (remaining == 0)) err($sformatf("disp_ready=%b with %0d workgroups left", vif.disp_ready, remaining));
    if (vif.busy !== (remaining != 0 || occ != 0)) err($sformatf("busy=%b but remaining=%0d occupied=%b", vif.busy, remaining, occ));
    if (vif.sm_want !== want) err($sformatf("sm_want=%b expected %b", vif.sm_want, want));

    if (remaining != 0 && !free_avail) begin
      if (occ == '1) cov.sample("all_slots_full_wait"); else cov.sample("sm_asleep_wait");
    end
    if (remaining != 0 && free_avail && !vif.launch_valid) err("work waiting and a free, awake slot exists, but no launch");
    if (vif.launch_valid) begin
      int s = vif.launch_slot;
      n_launch++;
      cov.sample($sformatf("slot_%0d", s));
      if (remaining == 0) err("launch with no workgroups left");
      if (occ[s]) err($sformatf("launch into occupied slot %0d", s));
      if (!vif.sm_avail[s % NSM]) err($sformatf("launch into slot %0d but SM%0d is asleep", s, s % NSM));
      if (vif.launch_wg_id !== next_wg) err($sformatf("launched workgroup %0d, expected %0d", vif.launch_wg_id, next_wg));
      if (vif.launch_pc !== k_pc || vif.launch_arg !== k_arg || vif.launch_nwarps !== k_nw)
        err($sformatf("launch config pc=%08h arg=%08h nw=%0d, expected pc=%08h arg=%08h nw=%0d",
                      vif.launch_pc, vif.launch_arg, vif.launch_nwarps, k_pc, k_arg, k_nw));
      if (vif.wg_done != 0) cov.sample("done_and_launch_same_cycle");
      if (freed_last[s]) cov.sample("slot_reused_next_cycle");
    end

    // next state
    if (vif.reg_wr_en) begin
      if (remaining != 0) cov.sample("cfg_written_while_launching");
      case (vif.reg_wr_addr)
        18'h100: cfg_pc = vif.reg_wr_data;
        18'h101: begin
          cfg_nw = (vif.reg_wr_data == 0) ? 1 : (vif.reg_wr_data > 4) ? 4 : vif.reg_wr_data[2:0];
          cov.sample(vif.reg_wr_data == 0 ? "nwarps_clamped_low" : vif.reg_wr_data > 4 ? "nwarps_clamped_high" : $sformatf("nwarps_%0d", vif.reg_wr_data));
        end
        18'h102: cfg_arg = vif.reg_wr_data;
        default: ;
      endcase
    end
    if (vif.disp_valid && vif.disp_ready) begin
      n_kernels++;
      if (occ != 0) cov.sample("dispatch_while_previous_running");
      cov.sample(vif.disp_num_wg == 0 ? "wg_count_zero" : vif.disp_num_wg == 1 ? "wg_count_one" :
                 vif.disp_num_wg <= NSLOT ? "wg_count_fits" : "wg_count_queues");
      remaining = vif.disp_num_wg; next_wg = 0;
      k_pc = cfg_pc; k_arg = cfg_arg; k_nw = cfg_nw;
    end else if (vif.launch_valid) begin
      remaining--; next_wg++;
    end
    freed_last = vif.wg_done;
    occ = (occ & ~vif.wg_done) | (vif.launch_valid ? (NSLOT'(1) << vif.launch_slot) : '0);
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("kernels=%0d launches=%0d errors=%0d", n_kernels, n_launch, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass
