// Cycle-accurate reference model written from the register specification.
// The RAL mirror cannot predict registers that hardware changes every cycle (status bits, counters,
// hang detection), so this model samples the same pins as the DUT every cycle, keeps its own copy of
// every register, checks every APB read value and every output, then computes the next state.
class rbbm_reference_model extends uvm_component;
  `uvm_component_utils(rbbm_reference_model)
  rbbm_vif_t vif;
  mgpu_coverage cov;

  bit [31:0] base, hang_to, hang_cnt, cnt[4];
  bit [9:0]  wptr;
  bit [3:0]  status, mask, sel[4];
  bit        bad_pkt_q, bad_op_q, soft_q;
  int        n_reads, n_writes, n_err;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("rbbm");
    foreach (names[i]) cov.add_bin(names[i]);
  endfunction
  string names[$] = '{
    "rd_ID", "rd_RING_BASE", "rd_RING_WPTR", "rd_RING_RPTR", "rd_IRQ_STATUS", "rd_IRQ_MASK", "rd_BUSY_STATUS",
    "rd_HANG_TIMEOUT", "rd_PERF_SEL", "rd_PERF_CNT",
    "wr_RING_BASE", "wr_RING_WPTR", "wr_IRQ_STATUS", "wr_IRQ_MASK", "wr_HANG_TIMEOUT", "wr_SOFT_RESET", "wr_PERF_SEL", "wr_PERF_CNT",
    "slverr_unmapped", "slverr_write_ro",
    "irq_src_fence", "irq_src_bad_pkt", "irq_src_bad_op", "irq_src_hang", "irq_masked_pending", "irq_line_high",
    "w1c_clear", "w1c_same_cycle_as_event", "hang_fired", "hang_count_reset_by_progress",
    "perf_counted_0", "perf_counted_1", "perf_counted_2", "perf_counted_3", "perf_write_same_cycle_as_event"};

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(rbbm_vif_t)::get(this, "", "vif", vif));
  endfunction

  function void err(string s);
    n_err++;
    `uvm_error("MODEL", s)
  endfunction

  function string rname(bit [11:0] a);
    case (a)
      12'h000: return "ID";          12'h004: return "RING_BASE";  12'h008: return "RING_WPTR";
      12'h00C: return "RING_RPTR";   12'h010: return "IRQ_STATUS"; 12'h014: return "IRQ_MASK";
      12'h018: return "BUSY_STATUS"; 12'h01C: return "HANG_TIMEOUT"; 12'h020: return "SOFT_RESET";
      default: return (a >= 12'h040 && a <= 12'h05C) ? (a[2] ? "PERF_CNT" : "PERF_SEL") : "UNMAPPED";
    endcase
  endfunction

  function bit [31:0] read_value(bit [11:0] a);
    case (a)
      12'h000: return 32'h6D47_5055;
      12'h004: return base;
      12'h008: return 32'(wptr);
      12'h00C: return 32'(vif.ring_rptr);
      12'h010: return 32'(status);
      12'h014: return 32'(mask);
      12'h018: return 32'(vif.busy_in);
      12'h01C: return hang_to;
      12'h020: return 32'h0;            // SOFT_RESET is write-only and reads 0
      default: return a[2] ? cnt[(a - 12'h044) / 8] : 32'(sel[(a - 12'h040) / 8]);
    endcase
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n !== 1) begin
        base = 0; hang_to = 0; hang_cnt = 0; wptr = 0; status = 0; mask = 0;
        bad_pkt_q = 0; bad_op_q = 0; soft_q = 0;
        foreach (cnt[i]) begin cnt[i] = 0; sel[i] = 0; end
        continue;
      end
      step();
    end
  endtask

  function void step();
    bit access = vif.psel && vif.penable;
    bit [11:0] a = vif.paddr;
    string n = rname(a);
    bit known = (n != "UNMAPPED");
    bit ro = (n == "ID" || n == "RING_RPTR" || n == "BUSY_STATUS");
    bit exp_err = access && (!known || (vif.pwrite && ro));
    bit wr_ok = access && vif.pwrite && !exp_err;
    bit [3:0] hw_set, w1c;
    bit any_busy = |vif.busy_in;
    bit hang_set;

    // 1. outputs must match the current state
    if (vif.irq !== |(status & mask)) err($sformatf("irq=%b but status=%h mask=%h", vif.irq, status, mask));
    if (vif.ring_base !== base) err($sformatf("ring_base output %h, expected %h", vif.ring_base, base));
    if (vif.ring_wptr !== wptr) err($sformatf("ring_wptr output %0d, expected %0d", vif.ring_wptr, wptr));
    if (vif.soft_reset !== soft_q) err($sformatf("soft_reset=%b, expected %b", vif.soft_reset, soft_q));
    if (status & ~mask) cov.sample("irq_masked_pending");
    if (vif.irq) cov.sample("irq_line_high");

    // 2. the APB access of this cycle
    if (access) begin
      if (vif.pslverr !== exp_err) err($sformatf("%s access to %03h: pslverr=%b expected %b", vif.pwrite ? "write" : "read", a, vif.pslverr, exp_err));
      if (exp_err) cov.sample(known ? "slverr_write_ro" : "slverr_unmapped");
      else if (vif.pwrite) begin n_writes++; cov.sample({"wr_", n}); end
      else begin
        bit [31:0] e = read_value(a);
        n_reads++;
        cov.sample({"rd_", n});
        if (vif.prdata !== e) err($sformatf("read %s (%03h) = %08h, expected %08h", n, a, vif.prdata, e));
      end
    end

    // 3. next state (what the DUT will hold after the coming clock edge)
    hang_set = (hang_to != 0) && (hang_cnt == hang_to - 1) && any_busy && !vif.progress;
    hw_set = {hang_set, vif.ev_bad_op && !bad_op_q, vif.ev_bad_pkt && !bad_pkt_q, vif.ev_fence};
    w1c = (wr_ok && a == 12'h010) ? vif.pwdata[3:0] : 4'h0;
    if (w1c & status) cov.sample("w1c_clear");
    if (w1c & hw_set) cov.sample("w1c_same_cycle_as_event");
    if (hw_set[0]) cov.sample("irq_src_fence");
    if (hw_set[1]) cov.sample("irq_src_bad_pkt");
    if (hw_set[2]) cov.sample("irq_src_bad_op");
    if (hw_set[3]) cov.sample("irq_src_hang");
    if (hang_set) cov.sample("hang_fired");
    if (hang_cnt > 0 && vif.progress && any_busy) cov.sample("hang_count_reset_by_progress");

    status = (status & ~w1c) | hw_set;
    if (!any_busy || vif.progress || hang_to == 0) hang_cnt = 0;
    else if (hang_cnt != hang_to - 1) hang_cnt++;
    else hang_cnt = 0;

    for (int i = 0; i < 4; i++) begin
      bit wr_cnt = wr_ok && a == 12'(12'h044 + 8 * i);
      bit ev = vif.perf_ev[sel[i]];
      if (wr_cnt && ev) cov.sample("perf_write_same_cycle_as_event");
      if (wr_cnt) cnt[i] = vif.pwdata;
      else if (ev) begin cnt[i]++; cov.sample($sformatf("perf_counted_%0d", i)); end
    end
    for (int i = 0; i < 4; i++) if (wr_ok && a == 12'(12'h040 + 8 * i)) sel[i] = vif.pwdata[3:0];
    if (wr_ok && a == 12'h004) base = {vif.pwdata[31:5], 5'd0};
    if (wr_ok && a == 12'h008) wptr = vif.pwdata[9:0];
    if (wr_ok && a == 12'h014) mask = vif.pwdata[3:0];
    if (wr_ok && a == 12'h01C) hang_to = vif.pwdata;
    soft_q = wr_ok && a == 12'h020 && vif.pwdata[0];
    bad_pkt_q = vif.ev_bad_pkt;
    bad_op_q  = vif.ev_bad_op;
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("MODEL", $sformatf("APB reads checked=%0d writes=%0d errors=%0d", n_reads, n_writes, n_err), UVM_LOW)
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass
