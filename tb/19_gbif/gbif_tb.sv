typedef virtual gbif_interface gbif_vif_t;

class gbif_config extends uvm_object;
  `uvm_object_utils(gbif_config)
  int rdy_pct = 70, max_lat = 6, err_pct = 0, write_pct = 50;
  bit wait_w_before_aw = 0;    // slave accepts AW only after it has seen WVALID (legal AXI behaviour)
  function new(string name = "gbif_config"); super.new(name); endfunction
endclass

class gbif_memory extends uvm_object;
  `uvm_object_utils(gbif_memory)
  bit [31:0] w[bit [31:0]];
  function new(string name = "gbif_memory"); super.new(name); endfunction
  function bit [31:0] rd(bit [31:0] a); return w.exists(a) ? w[a] : a ^ 32'h5A5A_0000; endfunction
endclass

// AXI4 slave model: random readiness on every channel, random latency, optional error responses,
// optional "wait for W before accepting AW".
class gbif_axi_slave extends uvm_component;
  `uvm_component_utils(gbif_axi_slave)
  gbif_vif_t vif; gbif_config cfg; gbif_memory mem;
  bit next_err;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(gbif_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(gbif_config)::get(this, "", "cfg", cfg));
    void'(uvm_config_db#(gbif_memory)::get(this, "", "mem", mem));
  endfunction
  function bit rdy(); return $urandom_range(99) < cfg.rdy_pct; endfunction
  task reads();
    forever begin
      bit [31:0] a; int len; bit e;
      vif.arready = 0;
      do begin @(posedge vif.clk); #1; vif.arready = rdy(); @(negedge vif.clk); end while (!(vif.arvalid && vif.arready));
      a = vif.araddr; len = vif.arlen; e = ($urandom_range(99) < cfg.err_pct);
      @(posedge vif.clk); #1; vif.arready = 0;
      repeat ($urandom_range(cfg.max_lat)) @(posedge vif.clk);
      for (int i = 0; i <= len; i++) begin
        #1; vif.rvalid = 1; vif.rdata = mem.rd(a + 4 * i); vif.rresp = (e && i == 3) ? 2'b10 : 2'b00; vif.rlast = (i == len);
        do @(negedge vif.clk); while (!vif.rready);
        @(posedge vif.clk);
        #1; vif.rvalid = 0;
        if (!rdy()) @(posedge vif.clk);
      end
    end
  endtask
  // write side as two independent processes, like real slaves: AW and W may be accepted in any order
  // (W beats are buffered until the address is known); the B response follows once both are complete
  bit [31:0] aw_q[$];
  int        aw_len_q[$];
  bit [31:0] w_data_q[$];
  bit [3:0]  w_strb_q[$];
  bit        w_last_q[$];
  task aw_side();
    vif.awready = 0;
    forever begin
      @(posedge vif.clk); #1;                     // ready only ever changes just after a rising edge
      vif.awready = (cfg.wait_w_before_aw && !vif.wvalid && w_data_q.size() == 0) ? 1'b0 : rdy();
      @(negedge vif.clk);
      if (vif.awvalid && vif.awready) begin aw_q.push_back(vif.awaddr); aw_len_q.push_back(vif.awlen); end
    end
  endtask
  task w_side();
    vif.wready = 0;
    forever begin
      @(posedge vif.clk); #1;
      vif.wready = rdy();
      @(negedge vif.clk);
      if (vif.wvalid && vif.wready) begin w_data_q.push_back(vif.wdata); w_strb_q.push_back(vif.wstrb); w_last_q.push_back(vif.wlast); end
    end
  endtask
  task b_side();
    forever begin
      bit [31:0] a; int len; bit e;
      @(posedge vif.clk); #1;
      if (aw_q.size() == 0 || w_data_q.size() < aw_len_q[0] + 1) continue;
      a = aw_q.pop_front(); len = aw_len_q.pop_front(); e = ($urandom_range(99) < cfg.err_pct);
      for (int i = 0; i <= len; i++) begin
        bit [31:0] v = mem.rd(a + 4 * i), d = w_data_q.pop_front();
        bit [3:0] s = w_strb_q.pop_front();
        void'(w_last_q.pop_front());
        for (int b = 0; b < 4; b++) if (s[b]) v[8*b +: 8] = d[8*b +: 8];
        if (s != 0) mem.w[a + 4 * i] = v;
      end
      repeat ($urandom_range(cfg.max_lat)) @(posedge vif.clk);
      #1; vif.bvalid = 1; vif.bresp = e ? 2'b10 : 2'b00;
      do @(negedge vif.clk); while (!vif.bready);
      @(posedge vif.clk); #1; vif.bvalid = 0;
    end
  endtask
  task run_phase(uvm_phase phase);
    vif.arready = 0; vif.rvalid = 0; vif.rlast = 0; vif.awready = 0; vif.wready = 0; vif.bvalid = 0;
    wait (vif.rst_n === 1);
    fork reads(); aw_side(); w_side(); b_side(); join
  endtask
endclass

// Every line request must become exactly one burst of the right kind and address; the line comes back
// assembled in order; errors on any beat or on B reach the requester.
class gbif_checker extends uvm_component;
  `uvm_component_utils(gbif_checker)
  gbif_vif_t vif; gbif_memory mem;
  mgpu_coverage cov;
  bit open, c_we, exp_err; bit [31:0] c_addr;
  bit [255:0] exp_line;
  int n, n_err, ar_cnt, aw_cnt;
  string names[$] = '{"read", "write", "read_error", "write_error", "aw_before_w", "w_before_aw", "aw_and_w_same_cycle",
                      "slave_stalls_ar", "slave_stalls_w", "partial_strobe_beat", "empty_strobe_beat"};
  bit aw_seen, w_seen;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("gbif");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(gbif_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(gbif_memory)::get(this, "", "mem", mem));
  endfunction
  function void err(string s); n_err++; `uvm_error("CHK", s) endfunction
  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) continue;
      if (vif.arvalid && !vif.arready) cov.sample("slave_stalls_ar");
      if (vif.wvalid && !vif.wready) cov.sample("slave_stalls_w");
      if (vif.arvalid && vif.arready) begin
        ar_cnt++;
        if (!open || c_we) err("read burst without a read request");
        if (vif.araddr !== c_addr || vif.arlen != 7 || vif.arsize != 2 || vif.arburst != 1) err("read burst attributes wrong");
        for (int i = 0; i < 8; i++) exp_line[32*i +: 32] = mem.rd(c_addr + 4 * i);
      end
      if (vif.rvalid && vif.rready && vif.rresp != 0) begin exp_err = 1; cov.sample("read_error"); end
      if (vif.awvalid && vif.awready) begin
        aw_cnt++;
        if (!open || !c_we) err("write burst without a write request");
        if (vif.awaddr !== c_addr || vif.awlen != 7 || vif.awsize != 2 || vif.awburst != 1) err("write burst attributes wrong");
        if (!w_seen && !(vif.wvalid && vif.wready)) cov.sample("aw_before_w");
        if (vif.wvalid && vif.wready && !w_seen) cov.sample("aw_and_w_same_cycle");
        aw_seen = 1;
      end
      if (vif.wvalid && vif.wready) begin
        if (!aw_seen && !(vif.awvalid && vif.awready)) cov.sample("w_before_aw");
        w_seen = 1;
        if (vif.wstrb == 0) cov.sample("empty_strobe_beat"); else if (vif.wstrb != 4'hF) cov.sample("partial_strobe_beat");
      end
      if (vif.bvalid && vif.bready && vif.bresp != 0) begin exp_err = 1; cov.sample("write_error"); end
      if (vif.rsp_valid) begin
        n++;
        if (!open) err("answer with no request");
        if (vif.rsp_err !== exp_err) err($sformatf("err=%b expected %b", vif.rsp_err, exp_err));
        if (!c_we && vif.rsp_data !== exp_line) err($sformatf("read line %08h assembled wrong", c_addr));
        open = 0;
      end
      if (vif.req_valid && vif.req_ready) begin
        open = 1; c_we = vif.req_we; c_addr = {vif.req_addr[31:5], 5'd0}; exp_err = 0; aw_seen = 0; w_seen = 0;
        cov.sample(c_we ? "write" : "read");
      end
    end
  endtask
  function void report_phase(uvm_phase phase);
    `uvm_info("CHK", $sformatf("lines=%0d read bursts=%0d write bursts=%0d errors=%0d", n, ar_cnt, aw_cnt, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass

class gbif_env extends uvm_env;
  `uvm_component_utils(gbif_env)
  gbif_axi_slave slv; gbif_checker chk;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    slv = gbif_axi_slave::type_id::create("slv", this);
    chk = gbif_checker::type_id::create("chk", this);
  endfunction
endclass

class gbif_base_test extends uvm_test;
  `uvm_component_utils(gbif_base_test)
  gbif_env env; gbif_config cfg; gbif_memory mem; gbif_vif_t vif;
  int n = 100;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = gbif_config::type_id::create("cfg");
    mem = gbif_memory::type_id::create("mem");
    knobs();
    uvm_config_db#(gbif_config)::set(this, "env.*", "cfg", cfg);
    uvm_config_db#(gbif_memory)::set(this, "env.*", "mem", mem);
    void'(uvm_config_db#(gbif_vif_t)::get(this, "", "vif", vif));
    env = gbif_env::type_id::create("env", this);
  endfunction
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    vif.req_valid = 0;
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    repeat (n) begin
      int t = 0;
      vif.req_valid = 1; vif.req_we = ($urandom_range(99) < cfg.write_pct); vif.req_addr = $urandom & 32'h000F_FFE0;
      for (int i = 0; i < 8; i++) vif.req_wdata[32*i +: 32] = $urandom;
      vif.req_wstrb = $urandom_range(2) == 0 ? '1 : $urandom;
      do @(negedge vif.clk); while (!vif.req_ready);
      @(posedge vif.clk); #1;
      vif.req_valid = 0;
      while (!vif.rsp_valid && t < 2000) begin @(negedge vif.clk); t++; end
      if (t >= 2000) begin `uvm_error("HANG", "no answer within 2000 cycles (deadlock)") break; end
      @(posedge vif.clk); #1;
    end
    repeat (5) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass
class gbif_smoke_test extends gbif_base_test;
  `uvm_component_utils(gbif_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass
class gbif_rand_test extends gbif_base_test;
  `uvm_component_utils(gbif_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 3000; endfunction
endclass
class gbif_error_test extends gbif_base_test;
  `uvm_component_utils(gbif_error_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 1500; cfg.err_pct = 20; endfunction
endclass
class gbif_w_first_slave_test extends gbif_base_test;
  `uvm_component_utils(gbif_w_first_slave_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); n = 1000; cfg.wait_w_before_aw = 1; cfg.write_pct = 80; endfunction
endclass
