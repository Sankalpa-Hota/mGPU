// Plays the rest of the sub-core: each cycle one warp executes the instruction at its pc with its mask.
// Plain instruction -> advance. Branch -> compute the taken lanes and send it, then wait for ctrl_done.
// Every executed (pc, lanes) is published so the checker can rebuild each lane's trace.
class simt_step extends uvm_object;
  `uvm_object_utils(simt_step)
  int warp; bit [31:0] pc, instr; bit [7:0] mask, taken;
  function new(string name = "simt_step"); super.new(name); endfunction
endclass

class simt_executor extends uvm_component;
  `uvm_component_utils(simt_executor)
  simt_vif_t vif;
  simt_program prog;
  simt_decider dec;
  uvm_analysis_port #(simt_step) step_ap;
  uvm_analysis_port #(int)       launch_ap;
  int visits[4][8][bit [31:0]];
  bit waiting[4];
  int rr;
  int rounds = 5, gap_pct = 20;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    step_ap = new("step_ap", this);
    launch_ap = new("launch_ap", this);
    void'(uvm_config_db#(simt_vif_t)::get(this, "", "vif", vif));
  endfunction

  task run_rounds();
    vif.wl_mask = 0; vif.adv_mask = 0; vif.br_valid = 0; vif.wl_pc = 0; vif.br_taken = 0; vif.br_warp = 0;
    vif.br_instr = 0; vif.br_pc = 0;
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    for (int round = 0; round < rounds; round++) begin
      dec.seed = $urandom;
      for (int w = 0; w < 4; w++) begin waiting[w] = 0; for (int l = 0; l < 8; l++) visits[w][l].delete(); end
      launch_ap.write(round);
      vif.wl_mask = 4'hF; vif.wl_pc = 0;
      @(posedge vif.clk); #1;
      vif.wl_mask = 0;
      while (vif.live != 0) begin
        int w = -1;
        vif.adv_mask = 0; vif.br_valid = 0;
        for (int k = 0; k < 4; k++) if (vif.ctrl_done[k]) waiting[k] = 0;
        if ($urandom_range(99) >= gap_pct)
          for (int k = 0; k < 4; k++) begin
            int c = (rr + k) % 4;
            if (w < 0 && vif.live[c] && !waiting[c]) w = c;
          end
        if (w >= 0) begin
          simt_step s = simt_step::type_id::create("s");
          bit [31:0] pc = vif.pc[w];
          bit [31:0] ins = prog.at(pc);
          rr = w + 1;
          s.warp = w; s.pc = pc; s.instr = ins; s.mask = vif.mask[w]; s.taken = 0;
          if (unit_of(f_op(ins)) == U_CTRL) begin
            if (f_op(ins) == OP_BEQ || f_op(ins) == OP_BNE)
              for (int l = 0; l < 8; l++)
                if (s.mask[l]) begin
                  int v = visits[w][l].exists(pc) ? visits[w][l][pc] : 0;
                  s.taken[l] = dec.taken(pc, ins, l, v);
                  visits[w][l][pc] = v + 1;
                end
            vif.br_valid = 1; vif.br_warp = w; vif.br_instr = ins; vif.br_pc = pc; vif.br_taken = s.taken;
            waiting[w] = 1;
          end else vif.adv_mask[w] = 1;
          step_ap.write(s);
        end
        @(posedge vif.clk); #1;
      end
      vif.adv_mask = 0; vif.br_valid = 0;
      repeat (3) @(posedge vif.clk); #1;
    end
  endtask
endclass
