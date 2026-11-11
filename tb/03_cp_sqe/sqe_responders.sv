// Plays the dispatcher and the rest of the GPU: random dispatch readiness; every accepted dispatch becomes a
// job that raises busy[0] 1..busy_delay_max cycles later and keeps it high for a random time.
// Background jobs on busy[1..7] model other blocks. Each job end is published so the scoreboard knows
// exactly when the work started by a DISPATCH was really finished.
class sqe_gpu_model extends uvm_component;
  `uvm_component_utils(sqe_gpu_model)
  sqe_vif_t vif;
  sqe_config cfg;
  uvm_analysis_port #(sqe_event) work_ap;
  int active[8];
  int next_id;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    work_ap = new("work_ap", this);
    void'(uvm_config_db#(sqe_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(sqe_config)::get(this, "", "cfg", cfg));
  endfunction
  function void update_busy();
    for (int b = 0; b < 8; b++) vif.busy_in[b] = (active[b] > 0);
  endfunction
  task job(int b, int delay, int len, int id);
    repeat (delay) @(posedge vif.clk);
    #1; active[b]++; update_busy();
    repeat (len) @(posedge vif.clk);
    #1; active[b]--; update_busy();
    if (b == 0) begin
      sqe_event e = sqe_event::type_id::create("e");
      e.kind = EV_WORK_END; e.t = $time / 10; e.work_id = id;
      work_ap.write(e);
    end
  endtask
  task run_phase(uvm_phase phase);
    vif.disp_ready = 0;
    vif.busy_in = '0;
    forever begin
      @(posedge vif.clk); #1;
      vif.disp_ready = ($urandom_range(99) < cfg.disp_rdy_pct);
      for (int b = 1; b < 8; b++)
        if ($urandom_range(99) < cfg.bg_busy_pct) begin
          int d = 0, l = $urandom_range(30, 1);
          fork job(b, d, l, -1); join_none
        end
      @(negedge vif.clk);
      if (vif.disp_valid && vif.disp_ready) begin
        int id = next_id++;
        int d = $urandom_range(cfg.busy_delay_max, 1);
        int l = $urandom_range(cfg.work_max, cfg.work_min);
        fork job(0, d, l, id); join_none
      end
    end
  endtask
endclass

// Plays memory for the fence write: random request readiness, random ack latency.
class sqe_memory_model extends uvm_component;
  `uvm_component_utils(sqe_memory_model)
  sqe_vif_t vif;
  sqe_config cfg;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(sqe_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(sqe_config)::get(this, "", "cfg", cfg));
  endfunction
  task run_phase(uvm_phase phase);
    vif.mreq_ready = 0;
    vif.mrsp_valid = 0;
    forever begin
      @(posedge vif.clk); #1;
      vif.mreq_ready = ($urandom_range(99) < cfg.mem_rdy_pct);
      @(negedge vif.clk);
      if (!(vif.mreq_valid && vif.mreq_ready)) continue;
      @(posedge vif.clk); #1;
      vif.mreq_ready = 0;
      repeat ($urandom_range(cfg.ack_max, cfg.ack_min)) @(posedge vif.clk);
      #1; vif.mrsp_valid = 1;
      @(posedge vif.clk); #1; vif.mrsp_valid = 0;
    end
  endtask
endclass
