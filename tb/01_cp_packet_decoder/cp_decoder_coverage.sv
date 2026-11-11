// Packet-level functional coverage, fed by the reference model (one sample per finished packet).
class cp_decoder_coverage extends uvm_subscriber #(cp_pkt_obs);
  `uvm_component_utils(cp_decoder_coverage)
  mgpu_coverage cov;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cov = new("cp_decoder");
    cov.add_bin("kind_T4");  cov.add_bin("kind_T7");  cov.add_bin("kind_BAD");
    foreach (cnt_names[i]) begin
      cov.add_bin({"t4_count_", cnt_names[i]});
      if (cnt_names[i] != "max") cov.add_bin({"t7_count_", cnt_names[i]});
    end
    cov.add_bin("op_dispatch"); cov.add_bin("op_event_write"); cov.add_bin("op_wait_idle"); cov.add_bin("op_other");
    cov.add_bin("payload_stalled"); cov.add_bin("payload_not_stalled");
    cov.add_bin("t4_reg_wrap");
    foreach (kinds[i]) foreach (kinds[j]) cov.add_bin({"order_", kinds[i], "_then_", kinds[j]});
  endfunction

  string cnt_names[5] = '{"zero", "one", "few", "mid", "max"};
  string kinds[3]     = '{"T4", "T7", "BAD"};

  function string kname(pkt_kind_e k);
    return k == PKT_T4 ? "T4" : k == PKT_T7 ? "T7" : "BAD";
  endfunction

  function string cname(int c);
    if (c == 0) return "zero";
    if (c == 1) return "one";
    if (c <= 8) return "few";
    if (c < 127) return "mid";
    return "max";
  endfunction

  function void write(cp_pkt_obs p);
    cov.sample({"kind_", kname(p.kind)});
    cov.sample({"order_", kname(p.prev_kind), "_then_", kname(p.kind)});
    if (p.kind == PKT_T4) begin
      cov.sample({"t4_count_", cname(p.count)});
      if (p.reg_wrap) cov.sample("t4_reg_wrap");
    end
    if (p.kind == PKT_T7) begin
      cov.sample({"t7_count_", cname(p.count > 40 ? 40 : p.count)});
      case (p.opcode)
        1: cov.sample("op_dispatch");
        2: cov.sample("op_event_write");
        3: cov.sample("op_wait_idle");
        default: cov.sample("op_other");
      endcase
    end
    if (p.kind != PKT_BAD && p.count > 0) cov.sample(p.stalled ? "payload_stalled" : "payload_not_stalled");
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("functional coverage = %0.1f%%%s", cov.percent(), cov.report()), UVM_LOW)
  endfunction
endclass
