class ring_rand_seq extends uvm_sequence #(ring_cmd);
  `uvm_object_utils(ring_rand_seq)
  int n_batches = 100, max_n = 12, max_gap = 10;
  function new(string name = "ring_rand_seq");
    super.new(name);
  endfunction
  task body();
    repeat (n_batches) begin
      ring_cmd c = ring_cmd::type_id::create("c");
      c.max_n = max_n; c.max_gap = max_gap;
      start_item(c);
      if (!c.randomize()) `uvm_fatal("RAND", "ring_cmd randomize failed")
      finish_item(c);
    end
  endtask
endclass

// Fill the ring right up to the "one slot free" limit, then drain, several times.
class ring_full_seq extends uvm_sequence #(ring_cmd);
  `uvm_object_utils(ring_full_seq)
  function new(string name = "ring_full_seq");
    super.new(name);
  endfunction
  task body();
    repeat (6) begin
      ring_cmd c = ring_cmd::type_id::create("c");
      start_item(c);
      c.n = RING_SIZE - 1; c.gap = 30;
      c.post_randomize();
      finish_item(c);
    end
  endtask
endclass
