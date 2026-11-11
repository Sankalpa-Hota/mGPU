class sqe_rand_seq extends uvm_sequence #(sqe_op);
  `uvm_object_utils(sqe_rand_seq)
  int n = 100, unknown_w = 0, max_gap = 2;
  function new(string name = "sqe_rand_seq");
    super.new(name);
  endfunction
  task body();
    repeat (n) begin
      sqe_op o = sqe_op::type_id::create("o");
      o.unknown_w = unknown_w; o.max_gap = max_gap;
      start_item(o);
      if (!o.randomize()) `uvm_fatal("RAND", "sqe_op randomize failed")
      finish_item(o);
    end
  endtask
endclass

// DISPATCH immediately followed by WAIT_FOR_IDLE on busy bit 0: the race the SETTLE window exists for.
class sqe_wfi_race_seq extends uvm_sequence #(sqe_op);
  `uvm_object_utils(sqe_wfi_race_seq)
  int n = 40;
  function new(string name = "sqe_wfi_race_seq");
    super.new(name);
  endfunction
  function sqe_op make(bit [6:0] op, bit [31:0] a0);
    sqe_op o = sqe_op::type_id::create("o");
    o.opcode = op; o.arg0 = a0; o.arg1 = 0; o.count = 1; o.gap = 0;
    o.post_randomize();
    return o;
  endfunction
  task body();
    repeat (n) begin
      sqe_op d = make(7'h01, $urandom_range(64, 1));
      sqe_op w = make(7'h03, 32'h1);
      start_item(d);
      finish_item(d);
      start_item(w);
      finish_item(w);
    end
  endtask
endclass

// EVENT_WRITE to every dword position of a line, then random ones.
class sqe_event_seq extends uvm_sequence #(sqe_op);
  `uvm_object_utils(sqe_event_seq)
  function new(string name = "sqe_event_seq");
    super.new(name);
  endfunction
  task body();
    for (int i = 0; i < 40; i++) begin
      sqe_op o = sqe_op::type_id::create("o");
      o.c_op.constraint_mode(0);
      o.c_extra.constraint_mode(0);
      start_item(o);
      if (!o.randomize() with { opcode == 7'h02; extra inside {[0:2]}; (i < 8) -> arg0[4:2] == i; }) `uvm_fatal("RAND", "ew")
      finish_item(o);
    end
  endtask
endclass
