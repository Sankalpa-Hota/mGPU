class cp_rand_seq extends uvm_sequence #(cp_pkt);
  `uvm_object_utils(cp_rand_seq)
  int n = 100;
  int t4_w = 45, t7_w = 45, bad_w = 0, zero_w = 5, max_w = 3, wrap_w = 3, max_gap = 0;
  function new(string name = "cp_rand_seq");
    super.new(name);
  endfunction
  task body();
    repeat (n) begin
      cp_pkt p = cp_pkt::type_id::create("p");
      p.t4_w = t4_w; p.t7_w = t7_w; p.bad_w = bad_w; p.zero_w = zero_w;
      p.max_w = max_w; p.wrap_w = wrap_w; p.max_gap = max_gap;
      start_item(p);
      if (!p.randomize()) `uvm_fatal("RAND", "cp_pkt randomize failed")
      finish_item(p);
    end
  endtask
endclass

// Directed: every corner listed in the plan, in a fixed order, before anything random.
class cp_directed_seq extends uvm_sequence #(cp_pkt);
  `uvm_object_utils(cp_directed_seq)
  function new(string name = "cp_directed_seq");
    super.new(name);
  endfunction
  task send(pkt_kind_e k, bit [17:0] r, bit [6:0] op, int c);
    cp_pkt p = cp_pkt::type_id::create("p");
    start_item(p);
    p.kind = k; p.reg_addr = r; p.opcode = op; p.count = c; p.bad_type = 4'h0; p.gap = 0;
    p.post_randomize();
    finish_item(p);
  endtask
  task body();
    send(PKT_T4, 18'h00100, 0, 1);      // single register write
    send(PKT_T4, 18'h00200, 0, 0);      // zero count type 4
    send(PKT_T7, 0, 7'h01, 0);          // zero count type 7
    send(PKT_T7, 0, 7'h02, 2);          // event write with two payload dwords
    send(PKT_T4, 18'h3FFFE, 0, 4);      // register address wraps past 0x3FFFF
    send(PKT_T4, 18'h01000, 0, 127);    // maximum type 4 count
    send(PKT_BAD, 0, 0, 0);             // unknown packet type
    send(PKT_T4, 18'h00300, 0, 2);      // decoder must recover after a bad header
    send(PKT_BAD, 0, 0, 0);             // second bad header: flag already set, no new event
    send(PKT_T7, 0, 7'h03, 1);
  endtask
endclass
