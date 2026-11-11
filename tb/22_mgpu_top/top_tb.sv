typedef virtual top_interface top_vif_t;

// Address map used by the tests (virtual addresses; identity mapped unless the test scrambles data pages)
localparam bit [31:0] RING_VA  = 32'h0006_0000;   // 1024-dword command ring
localparam bit [31:0] FENCE_VA = 32'h0007_0000;
localparam bit [31:0] PTBR_PA  = 32'h000F_0000;   // page tables (physical, never mapped)
typedef class top_data_writer;

class top_config extends uvm_object;
  `uvm_object_utils(top_config)
  bit scramble = 0;          // data pages (A, B, OUT) mapped to shuffled physical pages
  bit unmap_out = 0;         // OUT page left unmapped (expect an MMU fault)
  int idle_limit = 0;        // GMU power gating after this many idle cycles (0 = off)
  function new(string name = "top_config"); super.new(name); endfunction
endclass

// Plays the CPU and its GPU driver: APB register access, page tables, the command ring, kernel data, the
// interrupt, and the final comparison with the ISS.
class top_cpu extends uvm_component;
  `uvm_component_utils(top_cpu)
  top_vif_t vif; top_config cfg;
  mgpu_iss iss;
  mgpu_coverage cov;
  bit [31:0] va2pa[bit [31:0]];      // page map: VA page -> PA page
  int wptr, fence_val, n_err, n_kernels;
  longint t_total;
  string names[$] = '{"kernel_vector_add", "kernel_saxpy", "kernel_reduction", "kernel_divergence", "kernel_sfu",
                      "kernel_exit_barrier", "kernel_smem_conflict", "kernel_random", "mmu_identity", "mmu_scrambled",
                      "mmu_fault_reported", "gmu_power_cycles", "irq_per_kernel", "perf_counters_read", "back_to_back_kernels",
                      "ring_wraps"};
  function new(string name, uvm_component parent);
    super.new(name, parent);
    iss = new();
    cov = new("mgpu_system");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(top_vif_t)::get(this, "", "vif", vif));
    void'(uvm_config_db#(top_config)::get(this, "", "cfg", cfg));
  endfunction
  function void err(string s); n_err++; `uvm_error("CPU", s) endfunction

  // ---------------- APB
  task apb_write(bit [11:0] a, bit [31:0] d);
    @(posedge vif.clk); #1;
    vif.psel = 1; vif.penable = 0; vif.pwrite = 1; vif.paddr = a; vif.pwdata = d;
    @(posedge vif.clk); #1; vif.penable = 1;
    do @(negedge vif.clk); while (!vif.pready);
    if (vif.pslverr) err($sformatf("APB write %03h got SLVERR", a));
    @(posedge vif.clk); #1; vif.psel = 0; vif.penable = 0;
  endtask
  task apb_read(bit [11:0] a, output bit [31:0] d);
    @(posedge vif.clk); #1;
    vif.psel = 1; vif.penable = 0; vif.pwrite = 0; vif.paddr = a;
    @(posedge vif.clk); #1; vif.penable = 1;
    do @(negedge vif.clk); while (!vif.pready);
    d = vif.prdata;
    @(posedge vif.clk); #1; vif.psel = 0; vif.penable = 0;
  endtask

  // ---------------- physical memory (DRAM array, backdoor) and the VA view
  function bit [31:0] pa_of(bit [31:0] va);
    bit [31:0] pg = va & ~32'hFFF;
    return (va2pa.exists(pg) ? va2pa[pg] : pg) | (va & 32'hFFF);
  endfunction
  function void dram_wr(bit [31:0] pa, bit [31:0] d); tb_top.dut.u_dram.mem[pa[19:2]] = d; endfunction
  function bit [31:0] dram_rd(bit [31:0] pa); return tb_top.dut.u_dram.mem[pa[19:2]]; endfunction
  function void va_wr(bit [31:0] va, bit [31:0] d); dram_wr(pa_of(va), d); iss.wr(va, d); endfunction

  // page tables: VA pages 0x00000-0x7FFFF identity (or data pages shuffled), all writable
  function void build_page_tables();
    bit [31:0] l2 = PTBR_PA + 32'h1000;
    int perm[$];
    for (int i = 0; i < 64; i++) perm.push_back(i);
    perm.shuffle();
    dram_wr(PTBR_PA, l2 | 1);
    for (int p = 0; p < 128; p++) begin
      bit [31:0] va = p << 12, pa = va;
      if (cfg.scramble && va >= 32'h10000 && va < 32'h50000) pa = 32'h0008_0000 + (perm[p - 16] << 12);
      va2pa[va] = pa;
      if (!(cfg.unmap_out && va >= 32'h40000 && va < 32'h41000)) dram_wr(l2 + 4 * p, pa | 3);
      else dram_wr(l2 + 4 * p, 0);
    end
    cov.sample(cfg.scramble ? "mmu_scrambled" : "mmu_identity");
  endfunction

  // ---------------- command ring
  function void push(bit [31:0] dw);
    dram_wr(RING_VA + 4 * wptr, dw);    // the ring is identity mapped
    wptr = (wptr + 1) % 1024;
    if (wptr == 0) cov.sample("ring_wraps");
  endfunction
  function void t4(bit [17:0] reg_a, bit [31:0] vals[$]);
    push({4'h4, 2'b00, reg_a, 1'b0, 7'(vals.size())});
    foreach (vals[i]) push(vals[i]);
  endfunction
  function void t7(bit [6:0] op, bit [31:0] vals[$]);
    push({4'h7, 2'b00, 3'b000, op, 2'b00, 14'(vals.size())});
    foreach (vals[i]) push(vals[i]);
  endfunction
  task doorbell(); apb_write(12'h008, wptr); endtask

  task boot();
    bit [31:0] id;
    vif.psel = 0; vif.penable = 0; vif.pwrite = 0; vif.paddr = 0; vif.pwdata = 0;
    wait (vif.rst_n === 1);
    apb_read(12'h000, id);
    if (id != 32'h6D47_5055) err($sformatf("ID register %08h", id));
    build_page_tables();
    apb_write(12'h004, RING_VA);
    apb_write(12'h014, 4'b1111);          // all interrupts enabled
    apb_write(12'h01C, 32'd200000);       // hang watchdog
    apb_write(12'h040, 0); apb_write(12'h048, 4); apb_write(12'h050, 6); apb_write(12'h058, 10);   // perf: issue, TLB hit, row hit, SM power-off
    t4(18'h200, '{PTBR_PA, 32'd1});       // PTBR, MMU on
    t4(18'h202, '{32'd0});                // TLB invalidate
    t4(18'h204, '{cfg.idle_limit});
    doorbell();
  endtask

  task run_kernel(mgpu_kernel k);
    bit [31:0] st, f;
    int t = 0, mism = 0;
    longint t0;
    top_data_writer w = new(this);
    k.setup(w);
    if (!iss.run_kernel(k.pc0, k.num_wg, k.nw, k.arg)) err($sformatf("%s: ISS failed: %s", k.name, iss.error));
    cov.sample({"kernel_", (k.name inside {"vector_add", "saxpy", "reduction", "divergence", "sfu", "exit_barrier", "smem_conflict"}) ? k.name : "random"});
    if (n_kernels > 0) cov.sample("back_to_back_kernels");
    fence_val++;
    t4(18'h100, '{k.pc0, k.nw, k.arg});
    t7(7'h01, '{k.num_wg});               // DISPATCH
    t7(7'h03, '{32'h7});                  // WAIT_FOR_IDLE: dispatcher + SMs, L2, memory path
    t4(18'h203, '{32'd0});                // L2 clean + invalidate
    t7(7'h03, '{32'h6});                  // WAIT_FOR_IDLE: the flush has finished
    t7(7'h02, '{FENCE_VA, fence_val});    // EVENT_WRITE: fence + interrupt
    t0 = $time;
    doorbell();
    while (!vif.irq && t < 3000000) begin @(posedge vif.clk); t++; end
    if (!vif.irq) begin err($sformatf("%s: no interrupt (GPU hung)", k.name)); return; end
    apb_read(12'h010, st);
    if (!st[0]) err($sformatf("%s: interrupt but IRQ_STATUS=%h has no fence bit", k.name, st));
    if (st[3]) err($sformatf("%s: hang watchdog fired", k.name));
    apb_write(12'h010, st);               // W1C exactly what was read
    cov.sample("irq_per_kernel");
    f = dram_rd(pa_of(FENCE_VA));
    if (f != fence_val) err($sformatf("%s: fence %0d in memory, expected %0d", k.name, f, fence_val));
    if (!cfg.unmap_out) begin
      foreach (iss.mem[a]) if (dram_rd(pa_of(a)) !== iss.mem[a]) begin
        if (mism < 5) err($sformatf("%s: VA %08h (PA %08h) = %08h, ISS expects %08h", k.name, a, pa_of(a), dram_rd(pa_of(a)), iss.mem[a]));
        mism++;
      end
    end else if (vif.mmu_fault) begin
      cov.sample("mmu_fault_reported");
      if (vif.mmu_fault_va[31:12] != 20'h00040) err($sformatf("fault VA %08h is not in the unmapped OUT page", vif.mmu_fault_va));
    end else err("OUT page unmapped but no MMU fault was reported");
    n_kernels++;
    t_total += ($time - t0) / 10;
    `uvm_info("KERNEL", $sformatf("%-13s wg=%0d warps/wg=%0d threads=%0d  cycles=%0d  mismatches=%0d", k.name, k.num_wg, k.nw,
              k.threads(), ($time - t0) / 10, mism), UVM_LOW)
  endtask

  task report_perf();
    bit [31:0] c[4];
    apb_read(12'h044, c[0]); apb_read(12'h04C, c[1]); apb_read(12'h054, c[2]); apb_read(12'h05C, c[3]);
    cov.sample("perf_counters_read");
    if (c[3] != 0) cov.sample("gmu_power_cycles");
    `uvm_info("PERF", $sformatf("SM0 issue cycles=%0d  TLB hits=%0d  DRAM row hits=%0d  SM power-offs=%0d", c[0], c[1], c[2], c[3]), UVM_LOW)
  endtask
  function void report_phase(uvm_phase phase);
    `uvm_info("CPU", $sformatf("kernels=%0d total GPU cycles=%0d errors=%0d", n_kernels, t_total, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass

// writes a kernel's code, arguments and data into DRAM (through the VA map) and into the ISS
class top_data_writer extends mgpu_data_writer;
  top_cpu cpu;
  function new(top_cpu cpu); this.cpu = cpu; endfunction
  virtual function void write(bit [31:0] a, bit [31:0] d); cpu.va_wr(a, d); endfunction
endclass

class top_env extends uvm_env;
  `uvm_component_utils(top_env)
  top_cpu cpu;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cpu = top_cpu::type_id::create("cpu", this);
  endfunction
endclass

class top_base_test extends uvm_test;
  `uvm_component_utils(top_base_test)
  top_env env; top_config cfg; top_vif_t vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void knobs(); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = top_config::type_id::create("cfg");
    knobs();
    uvm_config_db#(top_config)::set(this, "env.*", "cfg", cfg);
    void'(uvm_config_db#(top_vif_t)::get(this, "", "vif", vif));
    env = top_env::type_id::create("env", this);
  endfunction
  virtual task kernels();
    mgpu_kernel k = new("vector_add", 4, 2);
    env.cpu.run_kernel(k);
  endtask
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    env.cpu.boot();
    kernels();
    env.cpu.report_perf();
    repeat (20) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
endclass
class top_smoke_test extends top_base_test;
  `uvm_component_utils(top_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass
class top_kernels_test extends top_base_test;
  `uvm_component_utils(top_kernels_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task kernels();
    string names[$] = '{"vector_add", "saxpy", "reduction", "divergence", "sfu", "exit_barrier", "smem_conflict"};
    foreach (names[i]) begin
      mgpu_kernel k = new(names[i], 6, (i % 3) + 2 > 4 ? 4 : (i % 3) + 2);
      env.cpu.run_kernel(k);
    end
  endtask
endclass
class top_random_test extends top_base_test;
  `uvm_component_utils(top_random_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task kernels();
    repeat (6) begin
      mgpu_kernel k = new("random", $urandom_range(8, 1), $urandom_range(4, 1), $urandom);
      env.cpu.run_kernel(k);
    end
  endtask
endclass
class top_scrambled_mmu_test extends top_kernels_test;
  `uvm_component_utils(top_scrambled_mmu_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cfg.scramble = 1; endfunction
endclass
class top_power_test extends top_kernels_test;
  `uvm_component_utils(top_power_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cfg.idle_limit = 30; endfunction
endclass
class top_mmu_fault_test extends top_base_test;
  `uvm_component_utils(top_mmu_fault_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void knobs(); cfg.unmap_out = 1; endfunction
endclass

// 70 small kernels back to back: about 1200 command dwords, so the 1024-dword ring wraps
class top_ring_wrap_test extends top_base_test;
  `uvm_component_utils(top_ring_wrap_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task kernels();
    repeat (70) begin
      mgpu_kernel k = new("vector_add", 1, 1);
      env.cpu.run_kernel(k);
    end
  endtask
endclass
