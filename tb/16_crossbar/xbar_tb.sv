typedef virtual xbar_interface xbar_vif_t;

class xbar_config extends uvm_object;
  `uvm_object_utils(xbar_config)
  int req_pct = 60, bank_rdy_pct = 60, bank_max_lat = 12, max_inflight = 4, hot_bank_pct = 0;
  function new(string name = "xbar_config"); super.new(name); endfunction
endclass

// Plays one requester (an SM, the CP fetch or the SQE): one request at a time, random lines, reads and writes.
class xbar_requester extends uvm_component;
  `uvm_component_utils(xbar_requester)
  xbar_vif_t vif; xbar_config cfg;
  int id, n_req;
  bit stop;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(xbar_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(xbar_config)::get(this, "", "cfg", cfg));
  endfunction
  task run_phase(uvm_phase phase);
    vif.req_valid[id] = 0;
    wait (vif.rst_n === 1);
    forever begin
      @(posedge vif.clk); #1;
      if (stop || $urandom_range(99) >= cfg.req_pct) continue;
      vif.req_valid[id] = 1;
      vif.req_addr[id] = {$urandom_range(63), 5'd0} | (($urandom_range(99) < cfg.hot_bank_pct) ? 32'h0 : 32'(($urandom & 1) << 5));
      vif.req_we[id] = $urandom_range(1);
      for (int i = 0; i < 8; i++) vif.req_wdata[id][32*i +: 32] = $urandom;
      vif.req_wstrb[id] = $urandom;
      do @(negedge vif.clk); while (!vif.req_ready[id]);
      @(posedge vif.clk); #1;
      vif.req_valid[id] = 0;
      while (!vif.rsp_valid[id]) @(negedge vif.clk);
      n_req++;
    end
  endtask
endclass

// Plays one L2 bank: accepts up to max_inflight requests, answers each after its own random latency, so the
// answers come back out of order. Every answer carries the request's id. A write answer echoes the write data
// (so the checker can see which request an answer belongs to); a read answer is a value derived from the address.
class xbar_bank extends uvm_component;
  `uvm_component_utils(xbar_bank)
  xbar_vif_t vif; xbar_config cfg;
  int b;
  typedef struct { int due; bit [1:0] id; bit [255:0] data; } pend_t;
  pend_t q[$];
  int inflight_max_seen;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(xbar_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(xbar_config)::get(this, "", "cfg", cfg));
  endfunction
  static function bit [255:0] answer(bit [31:0] a, bit we, bit [255:0] wd);
    bit [255:0] d;
    if (we) return wd;
    for (int i = 0; i < 8; i++) d[32*i +: 32] = (a + 4 * i) * 32'h9E3779B1;
    return d;
  endfunction
  task run_phase(uvm_phase phase);
    int cyc = 0;
    vif.b_ready[b] = 0; vif.b_rsp_valid[b] = 0;
    forever begin
      @(negedge vif.clk);
      cyc++;
      if (vif.b_valid[b] && vif.b_ready[b]) begin
        pend_t p;
        p.due = cyc + $urandom_range(cfg.bank_max_lat, 1); p.id = vif.b_id[b];
        p.data = answer(vif.b_addr[b], vif.b_we[b], vif.b_wdata[b]);
        q.push_back(p);
        if (q.size() > inflight_max_seen) inflight_max_seen = q.size();
      end
      @(posedge vif.clk); #1;
      vif.b_ready[b] = (q.size() < cfg.max_inflight) && ($urandom_range(99) < cfg.bank_rdy_pct);
      vif.b_rsp_valid[b] = 0;
      foreach (q[i]) if (q[i].due <= cyc) begin
        vif.b_rsp_valid[b] = 1; vif.b_rsp_id[b] = q[i].id; vif.b_rsp_data[b] = q[i].data;
        q.delete(i);
        break;
      end
    end
  endtask
endclass

// Follows every request: it must reach the bank its address belongs to, unchanged and with the right id,
// and its answer must come back to the same requester, exactly once.
class xbar_checker extends uvm_component;
  `uvm_component_utils(xbar_checker)
  xbar_vif_t vif;
  mgpu_coverage cov;
  bit        outstanding[4], accepted[4];
  bit [31:0] r_addr[4]; bit r_we[4]; bit [255:0] r_wdata[4]; bit [31:0] r_wstrb[4];
  int        waited_lost[4];
  int n_ok, n_err;
  string names[$] = '{"r0_bank0", "r0_bank1", "r1_bank0", "r1_bank1", "r2_bank0", "r2_bank1", "r3_bank0", "r3_bank1",
                      "two_requesters_one_bank", "four_requesting", "both_banks_accept", "two_answers_one_cycle",
                      "out_of_order_answers", "bank_backpressure"};
  int last_acc_order[2][$];
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("crossbar");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(xbar_vif_t)::get(this, "", "vif", vif));
  endfunction
  function void err(string s); n_err++; `uvm_error("CHK", s) endfunction
  task run_phase(uvm_phase phase);
    forever begin
      int per_bank[2];
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      per_bank = '{0, 0};
      for (int r = 0; r < 4; r++) if (vif.req_valid[r] && !accepted[r]) per_bank[vif.req_addr[r][5]]++;
      if (per_bank[0] >= 2 || per_bank[1] >= 2) cov.sample("two_requesters_one_bank");
      if (vif.req_valid == 4'hF) cov.sample("four_requesting");
      if ((vif.b_valid & vif.b_ready) == 2'b11) cov.sample("both_banks_accept");
      if (vif.b_rsp_valid == 2'b11) cov.sample("two_answers_one_cycle");
      for (int b = 0; b < 2; b++) if (vif.b_valid[b] && !vif.b_ready[b]) cov.sample("bank_backpressure");
      // out of order: a bank answers a request that is not the oldest one it holds
      for (int b = 0; b < 2; b++)
        if (vif.b_rsp_valid[b]) begin
          if (last_acc_order[b].size() != 0 && last_acc_order[b][0] != vif.b_rsp_id[b]) cov.sample("out_of_order_answers");
          foreach (last_acc_order[b][k]) if (last_acc_order[b][k] == vif.b_rsp_id[b]) begin last_acc_order[b].delete(k); break; end
        end
      // answers
      for (int r = 0; r < 4; r++)
        if (vif.rsp_valid[r]) begin
          bit [255:0] e = xbar_bank::answer(r_addr[r], r_we[r], r_wdata[r]);
          if (!accepted[r]) err($sformatf("answer to requester %0d which has no request in a bank", r));
          else if (vif.rsp_data[r] !== e) err($sformatf("requester %0d (addr %08h) got the answer of another request", r, r_addr[r]));
          else n_ok++;
          accepted[r] = 0; outstanding[r] = 0;
        end
      // bank side: what each bank received
      for (int b = 0; b < 2; b++)
        if (vif.b_valid[b] && vif.b_ready[b]) begin
          int r = vif.b_id[b];
          if (vif.b_addr[b][5] != b) err($sformatf("bank %0d received address %08h of bank %0d", b, vif.b_addr[b], vif.b_addr[b][5]));
          if (!vif.req_valid[r] || !vif.req_ready[r]) err($sformatf("bank %0d accepted for requester %0d, which was not handed over", b, r));
          else if (vif.b_addr[b] !== vif.req_addr[r] || vif.b_we[b] !== vif.req_we[r] || (vif.req_we[r] && vif.b_wdata[b] !== vif.req_wdata[r]))
            err($sformatf("request of requester %0d changed on the way to bank %0d", r, b));
          cov.sample($sformatf("r%0d_bank%0d", r, b));
          last_acc_order[b].push_back(r);
        end
      // requester side: handed over, and fairness
      for (int r = 0; r < 4; r++)
        if (vif.req_valid[r] && vif.req_ready[r]) begin
          accepted[r] = 1;
          r_addr[r] = vif.req_addr[r]; r_we[r] = vif.req_we[r]; r_wdata[r] = vif.req_wdata[r]; r_wstrb[r] = vif.req_wstrb[r];
          waited_lost[r] = 0;
        end
      for (int b = 0; b < 2; b++)
        if (vif.b_valid[b] && vif.b_ready[b])
          for (int r = 0; r < 4; r++)
            if (r != vif.b_id[b] && vif.req_valid[r] && !accepted[r] && vif.req_addr[r][5] == b) begin
              waited_lost[r]++;
              if (waited_lost[r] > 3) err($sformatf("requester %0d lost bank %0d arbitration %0d times in a row", r, b, waited_lost[r]));
            end
    end
  endtask
  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("answers delivered=%0d errors=%0d", n_ok, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass

class xbar_env extends uvm_env;
  `uvm_component_utils(xbar_env)
  xbar_requester rq[4]; xbar_bank bk[2]; xbar_checker chk;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    for (int r = 0; r < 4; r++) begin rq[r] = xbar_requester::type_id::create($sformatf("rq%0d", r), this); rq[r].id = r; end
    for (int b = 0; b < 2; b++) begin bk[b] = xbar_bank::type_id::create($sformatf("bank%0d", b), this); bk[b].b = b; end
    chk = xbar_checker::type_id::create("chk", this);
  endfunction
endclass

class xbar_base_test extends uvm_test;
  `uvm_component_utils(xbar_base_test)
  xbar_env env; xbar_config cfg; xbar_vif_t vif;
  int cycles = 2000;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = xbar_config::type_id::create("cfg");
    knobs();
    uvm_config_db#(xbar_config)::set(this, "env.*", "cfg", cfg);
    void'(uvm_config_db#(xbar_vif_t)::get(this, "", "vif", vif));
    env = xbar_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    int t = 0;
    phase.raise_objection(this);
    repeat (cycles) @(posedge vif.clk);
    for (int r = 0; r < 4; r++) env.rq[r].stop = 1;
    while ((env.chk.accepted.or() || vif.req_valid != 0) && t < 2000) begin @(posedge vif.clk); t++; end
    if (t >= 2000) `uvm_error("DRAIN", "requests still in flight at the end")
    repeat (10) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass
class xbar_smoke_test extends xbar_base_test;
  `uvm_component_utils(xbar_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass
class xbar_rand_test extends xbar_base_test;
  `uvm_component_utils(xbar_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 40000; endfunction
endclass
class xbar_hot_bank_test extends xbar_base_test;
  `uvm_component_utils(xbar_hot_bank_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 30000; cfg.hot_bank_pct = 90; cfg.req_pct = 100; cfg.bank_rdy_pct = 40; endfunction
endclass
class xbar_out_of_order_test extends xbar_base_test;
  `uvm_component_utils(xbar_out_of_order_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cycles = 30000; cfg.max_inflight = 4; cfg.bank_max_lat = 40; cfg.bank_rdy_pct = 90; cfg.req_pct = 100; endfunction
endclass
