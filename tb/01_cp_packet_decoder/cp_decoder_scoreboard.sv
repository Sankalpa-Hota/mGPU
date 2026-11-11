`uvm_analysis_imp_decl(_exp)
`uvm_analysis_imp_decl(_act)

// In-order scoreboard: the decoder never reorders, so expected and actual events must match one for one.
class cp_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(cp_scoreboard)
  uvm_analysis_imp_exp #(cp_out_item, cp_scoreboard) exp_imp;
  uvm_analysis_imp_act #(cp_out_item, cp_scoreboard) act_imp;
  cp_out_item exp_q[$];
  int n_match, n_err;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    exp_imp = new("exp_imp", this);
    act_imp = new("act_imp", this);
  endfunction

  function void write_exp(cp_out_item e);
    exp_q.push_back(e);
  endfunction

  function void write_act(cp_out_item a);
    cp_out_item e;
    if (exp_q.size() == 0) begin
      n_err++;
      `uvm_error("SB", $sformatf("unexpected output: %s", a.convert2string()))
      return;
    end
    e = exp_q.pop_front();
    if (!e.same(a)) begin
      n_err++;
      `uvm_error("SB", $sformatf("mismatch\n  expected: %s\n  actual:   %s", e.convert2string(), a.convert2string()))
    end else begin
      n_match++;
      `uvm_info("SB", $sformatf("match %s", a.convert2string()), UVM_HIGH)
    end
  endfunction

  function void check_phase(uvm_phase phase);
    if (exp_q.size() != 0)
      `uvm_error("SB", $sformatf("%0d expected outputs never appeared, first: %s", exp_q.size(), exp_q[0].convert2string()))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("outputs matched=%0d mismatched=%0d", n_match, n_err), UVM_LOW)
  endfunction
endclass
