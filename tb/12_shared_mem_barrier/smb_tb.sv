typedef virtual smb_interface smb_vif_t;
import mgpu_pkg::*;
localparam int WORDS = 128;

// ---------------------------------------------------------------- shared memory side
class smem_item extends uvm_sequence_item;
  `uvm_object_utils(smem_item)
  rand bit       we;
  rand bit [7:0] mask;
  rand int       pattern;   // 0 stride-4 (conflict free) 1 same word 2 stride-32 (one bank) 3 small region 4 anywhere
  rand bit [1:0] warp;
  rand bit [3:0] rd;
  bit [31:0] addr[8], wdata[8];
  int gap;
  constraint c_p { pattern inside {[0:4]}; }
  constraint c_m { mask dist {8'hFF :/ 50, 8'h00 :/ 3, [8'h01:8'hFE] :/ 47}; }
  function new(string name = "smem_item"); super.new(name); endfunction
  function void post_randomize();
    bit [31:0] base = $urandom_range(WORDS * 4 - 1) & ~3;
    for (int l = 0; l < 8; l++) begin
      case (pattern)
        0: addr[l] = base + 4 * l;
        1: addr[l] = base;
        2: addr[l] = base + 32 * l;
        3: addr[l] = (base & 32'h3C) + 4 * $urandom_range(15);
        default: addr[l] = $urandom & ~3;          // may be beyond 512: wraps
      endcase
      wdata[l] = $urandom;
    end
    gap = $urandom_range(2);
  endfunction
endclass

class smem_seq extends uvm_sequence #(smem_item);
  `uvm_object_utils(smem_seq)
  int n = 200;
  function new(string name = "smem_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      smem_item it = smem_item::type_id::create("it");
      start_item(it);
      if (!it.randomize()) `uvm_fatal("RAND", "smem item")
      finish_item(it);
    end
  endtask
endclass

class smem_driver extends uvm_driver #(smem_item);
  `uvm_component_utils(smem_driver)
  smb_vif_t vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(smb_vif_t)::get(this, "", "vif", vif));
  endfunction
  task run_phase(uvm_phase phase);
    vif.req_valid = 0;
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    forever begin
      seq_item_port.get_next_item(req);
      repeat (req.gap) begin @(posedge vif.clk); #1; end
      vif.req_valid = 1; vif.req_we = req.we; vif.req_mask = req.mask; vif.req_warp = req.warp; vif.req_rd = req.rd;
      for (int l = 0; l < 8; l++) begin vif.req_addr[l] = req.addr[l]; vif.req_wdata[l] = req.wdata[l]; end
      do @(negedge vif.clk); while (!vif.req_ready);
      @(posedge vif.clk); #1;
      vif.req_valid = 0;
      seq_item_port.item_done();
    end
  endtask
endclass

// Model memory, exact number of passes, and data per lane (writes in lane order: highest lane wins).
class smem_checker extends uvm_component;
  `uvm_component_utils(smem_checker)
  smb_vif_t vif;
  mgpu_coverage cov;
  bit [31:0] m[WORDS];
  bit open;
  int due, exp_passes, cyc, n, n_err;
  bit [31:0] e_data[8];
  bit e_we; bit [1:0] e_warp; bit [3:0] e_rd; bit [7:0] e_mask;
  bit [WORDS-1:0] written;
  string names[$] = '{"passes_1", "passes_2_4", "passes_5_7", "passes_8", "broadcast_read", "same_word_multi_write",
                      "empty_mask", "partial_mask", "address_wraps", "read_after_write", "write", "read"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("shared_mem");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(smb_vif_t)::get(this, "", "vif", vif));
  endfunction
  function void err(string s); n_err++; `uvm_error("SMEM", s) endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      cyc++;
      if (vif.rsp_valid) begin
        if (!open) err("response with no access in progress");
        else begin
          n++; open = 0;
          if (cyc != due) err($sformatf("response at cycle %0d, expected %0d (%0d passes)", cyc, due, exp_passes));
          if (vif.last_passes != exp_passes) err($sformatf("%0d passes reported, expected %0d", vif.last_passes, exp_passes));
          if (vif.rsp_we !== e_we || vif.rsp_warp !== e_warp || vif.rsp_rd !== e_rd || vif.rsp_mask !== e_mask) err("response routing wrong");
          if (!e_we) for (int l = 0; l < 8; l++)
            if (e_mask[l] && vif.rsp_data[l] !== e_data[l]) err($sformatf("lane %0d read %08h, expected %08h", l, vif.rsp_data[l], e_data[l]));
        end
      end
      if (vif.req_valid && vif.req_ready) accept();
    end
  endtask

  function void accept();
    int words_per_bank[8][$];
    int w[8];
    exp_passes = 0;
    for (int l = 0; l < 8; l++) begin
      w[l] = (vif.req_addr[l] >> 2) % WORDS;
      if (vif.req_mask[l]) begin
        bit seen = 0;
        foreach (words_per_bank[w[l] % 8][k]) if (words_per_bank[w[l] % 8][k] == w[l]) seen = 1;
        if (!seen) words_per_bank[w[l] % 8].push_back(w[l]);
        if (vif.req_addr[l] >= WORDS * 4) cov.sample("address_wraps");
      end
    end
    for (int b = 0; b < 8; b++) if (words_per_bank[b].size() > exp_passes) exp_passes = words_per_bank[b].size();
    open = 1; due = cyc + exp_passes + 2;
    e_we = vif.req_we; e_warp = vif.req_warp; e_rd = vif.req_rd; e_mask = vif.req_mask;
    cov.sample(e_we ? "write" : "read");
    if (e_mask == 0) cov.sample("empty_mask"); else if (e_mask != 8'hFF) cov.sample("partial_mask");
    if (exp_passes == 1) cov.sample("passes_1");
    else if (exp_passes >= 2 && exp_passes <= 4) cov.sample("passes_2_4");
    else if (exp_passes >= 5 && exp_passes <= 7) cov.sample("passes_5_7");
    else if (exp_passes == 8) cov.sample("passes_8");
    for (int l = 0; l < 8; l++) for (int k = l + 1; k < 8; k++)
      if (e_mask[l] && e_mask[k] && w[l] == w[k]) cov.sample(e_we ? "same_word_multi_write" : "broadcast_read");
    if (e_we) begin
      for (int l = 0; l < 8; l++) if (e_mask[l]) begin m[w[l]] = vif.req_wdata[l]; written[w[l]] = 1; end
    end else
      for (int l = 0; l < 8; l++) begin
        e_data[l] = m[w[l]];
        if (e_mask[l] && written[w[l]]) cov.sample("read_after_write");
      end
  endfunction
  function void check_phase(uvm_phase phase);
    if (open) err("access never answered");
  endfunction
  function void report_phase(uvm_phase phase);
    `uvm_info("SMEM", $sformatf("accesses=%0d errors=%0d", n, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass

// ---------------------------------------------------------------- barrier side
// Plays the warps of one workgroup: each warp works for a while, then executes BAR and waits for release,
// for several phases; some warps EXIT early. Only one arrival per cycle (one issue port).
class barrier_driver extends uvm_component;
  `uvm_component_utils(barrier_driver)
  smb_vif_t vif;
  int workgroups = 20, phases = 4, exit_pct = 10, max_work = 10;
  bit done;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(smb_vif_t)::get(this, "", "vif", vif));
  endfunction
  task run_phase(uvm_phase phase);
    vif.wl_mask = 0; vif.live = 0; vif.arrive_valid = 0; vif.arrive_warp = 0;
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    repeat (workgroups) begin
      int nw = $urandom_range(4, 1);
      int phase_of[4], work_left[4];
      bit want[4], at_bar[4];
      bit [3:0] members = (4'b1 << nw) - 1;
      vif.wl_mask = members; vif.live = members;
      for (int w = 0; w < 4; w++) begin phase_of[w] = 0; work_left[w] = $urandom_range(max_work); want[w] = 0; at_bar[w] = 0; end
      @(posedge vif.clk); #1;
      vif.wl_mask = 0;
      while (vif.live != 0) begin
        int pick = -1;
        vif.arrive_valid = 0;
        for (int w = 0; w < 4; w++) begin
          if (vif.release_mask[w]) begin at_bar[w] = 0; phase_of[w]++; work_left[w] = $urandom_range(max_work); end
          if (!vif.live[w] || at_bar[w] || want[w]) continue;
          if (work_left[w] > 0) work_left[w]--;
          else if (phase_of[w] >= phases || $urandom_range(99) < exit_pct) vif.live[w] = 0;   // EXIT
          else want[w] = 1;
        end
        for (int w = 0; w < 4; w++) if (pick < 0 && want[w]) pick = w;
        if (pick >= 0) begin
          vif.arrive_valid = 1; vif.arrive_warp = pick; want[pick] = 0; at_bar[pick] = 1;
        end
        @(posedge vif.clk); #1;
      end
      vif.arrive_valid = 0;
      repeat (3) @(posedge vif.clk); #1;
    end
    done = 1;
  endtask
endclass

// Cycle model of the barrier: the release must happen exactly one cycle after the cycle in which every live
// member has arrived, release exactly the arrived warps, and never otherwise.
class barrier_checker extends uvm_component;
  `uvm_component_utils(barrier_checker)
  smb_vif_t vif;
  mgpu_coverage cov;
  bit [3:0] arrived, exp_release;
  int n_rel, n_err;
  string names[$] = '{"wg_1_warp", "wg_4_warps", "release_by_last_arrival", "release_by_exit", "warps_exited_before_barrier",
                      "back_to_back_barriers", "relaunch_while_idle"};
  bit [3:0] prev_live;
  int last_release = -10, cyc;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("barrier");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(smb_vif_t)::get(this, "", "vif", vif));
  endfunction
  function void err(string s); n_err++; `uvm_error("BAR", s) endfunction
  task run_phase(uvm_phase phase);
    forever begin
      bit [3:0] now;
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      cyc++;
      if (vif.release_mask !== exp_release) err($sformatf("release %b, expected %b", vif.release_mask, exp_release));
      if (vif.release_mask != 0) n_rel++;
      exp_release = 0;
      if (vif.wl_mask != 0) begin
        arrived = 0; prev_live = vif.wl_mask;
        if (vif.wl_mask == 4'b0001) cov.sample("wg_1_warp");
        if (vif.wl_mask == 4'b1111) cov.sample("wg_4_warps");
        cov.sample("relaunch_while_idle");
        continue;
      end
      now = arrived;
      if (vif.arrive_valid) now[vif.arrive_warp] = 1;
      if (now != 0 && (vif.live & ~now) == 0) begin
        exp_release = now;
        if (vif.arrive_valid) cov.sample("release_by_last_arrival"); else cov.sample("release_by_exit");
        if ((prev_live & ~vif.live) != 0 || vif.live != prev_live) cov.sample("warps_exited_before_barrier");
        if (cyc - last_release < 4) cov.sample("back_to_back_barriers");
        last_release = cyc;
        arrived = 0;
      end else arrived = now;
    end
  endtask
  function void report_phase(uvm_phase phase);
    `uvm_info("BAR", $sformatf("releases=%0d errors=%0d", n_rel, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass

class smb_env extends uvm_env;
  `uvm_component_utils(smb_env)
  uvm_sequencer #(smem_item) sqr;
  smem_driver drv; smem_checker schk; barrier_driver bdrv; barrier_checker bchk;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = uvm_sequencer#(smem_item)::type_id::create("sqr", this);
    drv = smem_driver::type_id::create("drv", this);
    schk = smem_checker::type_id::create("schk", this);
    bdrv = barrier_driver::type_id::create("bdrv", this);
    bchk = barrier_checker::type_id::create("bchk", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class smb_base_test extends uvm_test;
  `uvm_component_utils(smb_base_test)
  smb_env env; smb_vif_t vif;
  int n = 100, wgs = 10, phases = 3, exit_pct = 10;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(smb_vif_t)::get(this, "", "vif", vif));
    env = smb_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    smem_seq s = smem_seq::type_id::create("s");
    int t = 0;
    phase.raise_objection(this);
    knobs();
    env.bdrv.workgroups = wgs; env.bdrv.phases = phases; env.bdrv.exit_pct = exit_pct;
    s.n = n;
    s.start(env.sqr);
    while (!env.bdrv.done && t < 200000) begin @(posedge vif.clk); t++; end
    if (!env.bdrv.done) `uvm_error("DRAIN", "barrier workgroups did not finish (deadlock)")
    repeat (10) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass
class smb_smoke_test extends smb_base_test;
  `uvm_component_utils(smb_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass
class smb_rand_test extends smb_base_test;
  `uvm_component_utils(smb_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 3000; wgs = 200; phases = 5; endfunction
endclass
class smb_exit_test extends smb_base_test;
  `uvm_component_utils(smb_exit_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 500; wgs = 300; phases = 6; exit_pct = 30; endfunction
endclass
